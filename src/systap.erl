-module(systap).

%% API exports
-export([main/1]).

%%====================================================================
%% API functions
%%====================================================================

%% escript Entry point
main([]) ->
    AllBeers = fetch_all_beers(1),
    file:write_file(
      "index.html",
      unicode:characters_to_binary(
        lists:flatten(create_html(AllBeers)))).

get_beers(coming, AllBeers) ->
    io:format("Fetch coming beers:~n"),
    get_beers(AllBeers, calendar:system_time_to_rfc3339(erlang:system_time(seconds)), infinity);
get_beers(lastWeek, AllBeers) ->
    io:format("Fetch last weeks beers:~n"),
    Now = erlang:system_time(seconds),
    get_beers(AllBeers,
              calendar:system_time_to_rfc3339(Now - 60 * 60 * 24 * 7),
              calendar:system_time_to_rfc3339(Now));
get_beers(lastMonth, AllBeers) ->
    io:format("Fetch last months beers:~n"),
    Now = erlang:system_time(seconds),
    get_beers(AllBeers,
              calendar:system_time_to_rfc3339(Now - 60 * 60 * 24 * 30),
              calendar:system_time_to_rfc3339(Now)).
get_beers(AllBeers, FromDate, ToDate) ->
    FromDateS = calendar:rfc3339_to_system_time(FromDate),
    ToDateS = if is_list(ToDate) -> calendar:rfc3339_to_system_time(ToDate);
                 true -> ToDate
              end,
    Beers = lists:filter(
              fun(#{ <<"productLaunchDate">> := Date} = Beer) ->
                      DateS = calendar:rfc3339_to_system_time(binary_to_list(Date)++"Z"),
                      FromDateS =< DateS andalso DateS =< ToDateS
              end, AllBeers),
    [add_beer_stats(B) || B <- Beers].

get_beer_name(Beer) ->
    case maps:get(<<"productNameThin">>,Beer) of
        null ->
            maps:get(<<"productNameBold">>,Beer);
        Name ->
            Name
    end.

get_producer_name(Beer) ->
    maps:get(<<"producerName">>, Beer).

add_beer_stats(#{ <<"productId">> := SId } = Beer) ->
    Id = binary_to_integer(SId),
    case file:consult("override.term") of
        {ok, [#{ Id := Name }] } ->
            case fetch_beer_stats(Name) of
                [#{ } = Untappd|_] ->
                    Beer#{ untappd => Untappd };
                _ ->
                    io:format("Could not find override: '~ts' (~ts)~n", [Name, SId]),
                    Beer#{ untappd => #{ id => "0" } }
            end;
        _ ->
            Name = get_beer_name(Beer),
            Producer = get_producer_name(Beer),
            case fetch_beer_stats([Name, " ", Producer]) of
                [#{ } = Untappd|_] ->
                    Beer#{ untappd => Untappd };
                [] ->
                    case fetch_beer_stats([Name, " ", hd(string:split(Producer, " ", trailing))]) of
                        [] ->
                            case fetch_beer_stats([hd(string:split(Name, " ", trailing)), " ", Producer]) of
                                [] ->
                                    io:format("~ts => \"~ts\",~n",
                                              [SId, [Name, " ", Producer]]),
                                    Beer#{ untappd => #{ id => "0" } };
                                [#{ } = Untappd|_] ->
                                    Beer#{ untappd => Untappd }
                            end;
                        [#{ } = Untappd|_] ->
                            Beer#{ untappd => Untappd }
                    end
            end
    end.

fetch_all_beers(-1) ->
    [];
fetch_all_beers(Page) ->
    Data = try_cache("bolaget."++integer_to_list(Page),
                     fun() ->
                             io:format("Fetching page: ~tp~n",[Page]),
                             os:cmd(unicode:characters_to_list(
                                      ["curl -s 'https://www.systembolaget.se/api/gateway/productsearch/search/?categoryLevel1=%C3%96l&page=",integer_to_list(Page),
                                       "' -H 'baseURL: https://api-systembolaget.azure-api.net/sb-api-ecommerce/v1'"])) end),
    Json = try
               jsx:decode(Data,[])
           catch E:R:ST ->
                   io:format("Failed to decode ~ts~n",[Data]),
                   erlang:raise(E,R,ST)
           end,
    Products = maps:get(<<"products">>, Json) ++
        fetch_all_beers(maps:get(<<"nextPage">>,maps:get(<<"metadata">>, Json))).

fetch_beer_stats(Name) ->
    QName = uri_string:quote(Name),
    Page = try_cache("untappd"++QName,
                     fun() ->
                             %% Res = os:cmd("curl -s https://untappd.com/search?q="++QName),
                             %% case re:run(Res, "Enable JavaScript and cookies to continue",[unicode]) of
                             %%     {match, _} ->
                                     io:format("Trying selenium ~ts~n",[QName]),
                                     selenium("https://untappd.com/search?q="++QName)%% ;
                                 %% _ ->
                                 %%     Res
                             %% end
                     end),
    case string:trim(Page) of
        "" ->
            [];
        _ ->
            {ok, Beers, []} = htmerl:sax(Page, [{event_fun, fun event_fun/3},
                                                {user_state, #{ current => undefined,
                                                                beers => [] }}]),
            Beers
    end.

try_cache(Name, Fun) ->
    TmpFile = "cache/"++Name,
    ok = filelib:ensure_dir(TmpFile),
    case file:read_file(TmpFile) of
        {ok,B} -> B;
        _ ->
            B = unicode:characters_to_binary(Fun()),
            file:write_file(TmpFile, B),
            B
    end.

%%====================================================================
%% Internal functions
%%====================================================================
event_fun({startElement,_,<<"div">>,_,[{_,_,<<"class">>,<<"beer-item ">>}]},
          _, S = #{ beers := T, current := #{ id := Id } = C }) ->
    S#{ beers => [C|T], current := undefined };
event_fun({startElement,_,<<"a">>,_,[{_,_,<<"class">>,<<"label">>},
                                     {_,_,<<"href">>,Href}]}, _,
          S = #{ current := undefined }) ->
    S#{ current := #{ id => Href } };
event_fun({startElement,_,<<"p">>,_,[{_,_,<<"class">>,<<"name">>}]}, _,
          S = #{ current := C }) ->
    S#{ collect => name };
event_fun({startElement,_,<<"p">>,_,[{_,_,<<"class">>,<<"brewery">>}]}, _,
          S = #{ current := C }) ->
    S#{ collect => brewery };
event_fun({startElement,_,<<"p">>,_,[{_,_,<<"class">>,<<"style">>}]}, _,
          S = #{ current := C }) ->
    S#{ collect => style };
event_fun({startElement,_,<<"p">>,_,[{_,_,<<"class">>,<<"abv">>}]}, _,
          S = #{ current := C }) ->
    S#{ collect => abv };
event_fun({startElement,_,<<"p">>,_,[{_,_,<<"class">>,<<"ibu">>}]}, _,
          S = #{ current := C }) ->
    S#{ collect => ibu };
event_fun({startElement,_,<<"div">>,_,[{_,_,<<"class">>,<<"caps">>},
                                       {_,_,<<"data-rating">>,Rating}]}, _,
          S = #{ current := C }) ->
    S#{ current := C#{ rating => Rating }};
event_fun({characters,Chars}, _,
          S = #{ collect := Label, current := C })
  when Label =/= undefined ->
    S#{ current := C#{ Label => Chars }, collect => undefined };
event_fun(endDocument, _, S = #{ current := C }) when C =/= undefined ->
    lists:reverse([C|maps:get(beers, S)]);
event_fun(endDocument, _, S = #{ current := C }) ->
    lists:reverse(maps:get(beers, S));
event_fun(Event, _, S) ->
    % io:format("Ignored: ~tp~n",[Event]),
    S.

create_html(Beers) ->
    ["<!DOCTYPE html>
<html>
<head>
	<title>Beer List</title>
	<!-- Include Bootstrap CSS -->
	<link rel=\"stylesheet\" href=\"https://maxcdn.bootstrapcdn.com/bootstrap/4.0.0/css/bootstrap.min.css\">
	<!-- Include tablesorter CSS -->
	<link rel=\"stylesheet\" href=\"https://cdnjs.cloudflare.com/ajax/libs/jquery.tablesorter/2.31.3/css/theme.bootstrap_4.min.css\" />
</head>
<body>
	<div class=\"container mt-5\">
		<h1 class=\"text-center mb-5\">Beer List</h1>

                <!-- Create tabs for different time periods -->
		<ul class=\"nav nav-tabs\" id=\"myTab\" role=\"tablist\">
			<li class=\"nav-item\">
				<a class=\"nav-link active\" id=\"coming-tab\" data-toggle=\"tab\" href=\"#coming\" role=\"tab\" aria-controls=\"coming\" aria-selected=\"true\">Coming</a>
			</li>
			<li class=\"nav-item\">
				<a class=\"nav-link\" id=\"last-week-tab\" data-toggle=\"tab\" href=\"#last-week\" role=\"tab\" aria-controls=\"last-week\" aria-selected=\"false\">Last week</a>
			</li>
			<li class=\"nav-item\">
				<a class=\"nav-link\" id=\"last-month-tab\" data-toggle=\"tab\" href=\"#last-month\" role=\"tab\" aria-controls=\"last-month\" aria-selected=\"false\">Last month</a>
			</li>
		</ul>
<div class=\"tab-content\" id=\"myTabContent\">
", create_html_table("coming", get_beers(coming, Beers)),
create_html_table("last-week", get_beers(lastWeek, Beers)),
create_html_table("last-month", get_beers(lastMonth, Beers)),
     "
	</div></div>
	<!-- Include jQuery and tablesorter JS -->
	<script src=\"https://code.jquery.com/jquery-3.2.1.slim.min.js\"></script>
	<script src=\"https://cdnjs.cloudflare.com/ajax/libs/jquery.tablesorter/2.31.3/js/jquery.tablesorter.min.js\"> </script>
        <script src=\"https://maxcdn.bootstrapcdn.com/bootstrap/4.0.0/js/bootstrap.min.js\" crossorigin=\"anonymous\"></script>
	<!-- Initialize tablesorter plugin -->
	<script>
			// Initialize tablesorter plugin
			$(\".tablesorter\").tablesorter({});
	</script>
</body>
</html>"].

create_html_table(TabName, Beers) ->
    ["<!-- ",TabName," tab -->
			<div class=\"tab-pane fade ",["show active"|| TabName =:= "coming" ],"\" id=\"",TabName,"\" role=\"tabpanel\" aria-labelledby=\"",TabName,"-tab\">
		<table class=\"table table-bordered tablesorter\">
			<thead class=\"thead-dark\">
				<tr>
                                        <th>Icon</th>
					<th>Name</th>
					<th>Brewery</th>
					<th>Rating</th>
					<th>Price</th>
					<th>Style</th>
					<th>Release Date</th>
					<th>Systembolaget</th>
					<th>Untappd</th>
				</tr>
			</thead>
			<tbody>",
     [["<tr>
	  <td>",[["<img style=\"height: 80px; width: 30px; inset: 0px; color: transparent;\" src=\"",maps:get(<<"imageUrl">>,hd(maps:get(<<"images">>,Beer))),"_400.png?q=75&amp;w=375\"></img>"] || maps:get(<<"images">>,Beer) =/= []],
       "</td>"
       "<td><b>",maps:get(<<"productNameBold">>,Beer,""),"</b><br/>",case maps:get(<<"productNameThin">>,Beer) of null -> ""; Name -> Name end,"</div></div></td>
	  <td>",maps:get(brewery,maps:get(untappd,Beer),maps:get(<<"producerName">>, Beer)),"</td>
	  <td>",maps:get(rating,maps:get(untappd,Beer),"0.0"),"</td>
	  <td>",float_to_list(maps:get(<<"price">>,Beer)*1.0,[{decimals,2}])," SEK</td>
	  <td>",maps:get(style,maps:get(untappd,Beer),"N/A"),"</td>
          <td>",maps:get(<<"productLaunchDate">>,Beer),"</td>
	  <td><a href=\"https://www.systembolaget.se/",maps:get(<<"productNumber">>,Beer),"\">Link</a></td>
	  <td>",[["<a href=\"https://untappd.com/",maps:get(id,maps:get(untappd,Beer)),"\">Link</a>"] || maps:get(id,maps:get(untappd,Beer)) =/= "0"],"</td>
       </tr>"] || Beer <- Beers],"
			</tbody>
		</table></div>"].


% <img alt="Produktbild för Melleruds" sizes="100vw" srcset="https://product-cdn.systembolaget.se/productimages/33194844/33194844_400.png?q=75&amp;w=375 375w, https://product-cdn.systembolaget.se/productimages/33194844/33194844_400.png?q=75&amp;w=384 384w, https://product-cdn.systembolaget.se/productimages/33194844/33194844_400.png?q=75&amp;w=768 768w, https://product-cdn.systembolaget.se/productimages/33194844/33194844_400.png?q=75&amp;w=1024 1024w, https://product-cdn.systembolaget.se/productimages/33194844/33194844_400.png?q=75&amp;w=1208 1208w, https://product-cdn.systembolaget.se/productimages/33194844/33194844_400.png?q=75&amp;w=2000 2000w" src="https://product-cdn.systembolaget.se/productimages/33194844/33194844_400.png?q=75&amp;w=2000" decoding="async" data-nimg="fill" class="css-srqzl3 e53gfhp1" style="position: absolute; height: 100%; width: 100%; inset: 0px; color: transparent;">


selenium(Url) ->
    Tmp = string:trim(os:cmd("mktemp")),
    file:write_file(
     Tmp,
      "from selenium.webdriver.chrome.options import Options
from selenium.webdriver.support.wait import WebDriverWait
from selenium.webdriver.common.by import By
import chromedriver_autoinstaller
import undetected_chromedriver as uc
options = Options()
options.add_argument(\"--headless=new\")
driver = uc.Chrome(options=options)
driver.get('"++Url++"')
try:
    WebDriverWait(driver, timeout=3).until(lambda d: d.find_element(By.CLASS_NAME,'beer-list'))
    html = driver.page_source
    print(html)
finally:
    driver.quit()"),
     os:cmd("timeout -k 2m 1m python3 "++Tmp).
