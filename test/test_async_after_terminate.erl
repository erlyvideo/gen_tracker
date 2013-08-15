-module(test_async_after_terminate).

-compile(export_all).


start_link(Name, Parent) ->
  gen_server:start_link(?MODULE, [Name, Parent], []).


init([Name, Parent]) ->
  gen_tracker:setattr(test_tracker, Name, parent, Parent),
  {ok, Parent}.


handle_info(stop, Parent) ->
  {stop, normal, Parent}.


terminate(_,_) ->
  ok.


after_terminate(Name, Attrs) ->
  Parent = proplists:get_value(parent, Attrs),
  Parent ! {dying, Name, self()},
  receive
    get_away -> ok
  end.

