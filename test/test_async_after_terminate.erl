-module(test_async_after_terminate).

-compile(nowarn_export_all).
-compile(export_all).


start_link(Name, Parent) ->
  proc_lib:start_link(?MODULE, init, [[Name, Parent]]).


init([Name, Parent]) ->
  gen_tracker:init_ack({ok,self()}),
  gen_tracker:setattr(test_tracker, Name, parent, Parent),
  gen_tracker:setattr(test_tracker, Name, child, self()),
  gen_server:enter_loop(?MODULE, [], Parent).


handle_info(stop, Parent) ->
  {stop, normal, Parent}.


terminate(_,_) ->
  ok.


after_terminate(Name, Attrs) ->
  [ReportTo ! {after_terminate, Name, Attrs, self()} || is_pid(ReportTo = whereis(?MODULE))],
  Parent = proplists:get_value(parent, Attrs),
  %Tracker = proplists:get_value(tracker, Attrs),
  %[ct:pal("Worker ~w Attrs ~0p~n~120p", [self(), Attrs, erlang:process_info(self(), current_stacktrace)]) || Attrs == [] orelse Tracker == self() orelse (not is_pid(Parent))],
  Parent ! {dying, Name, self()},
  receive
    get_away -> ok
  end.

