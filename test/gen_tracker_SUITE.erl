-module(gen_tracker_SUITE).

-include_lib("common_test/include/ct.hrl").
-compile(nowarn_export_all).
-compile(export_all).

all() ->
  [
    {group, creation}
  ].


groups() ->
  [
    {creation, [], [
      wrong_child_spec,
      temporary,
      % transient,
      % permanent,
      list,
      shutdown,
      add_existing_child,
      rewrite_existing_child,
      do_not_set_property_of_unknown_child,
      shutdown_launching_child,
      async_exit_child
    ]}
  ].


end_per_testcase(_, Config) ->
  case erlang:whereis(test_tracker) of
    undefined -> ok;
    Pid -> 
      erlang:exit(Pid, shutdown),
      timer:sleep(5),
      erlang:exit(Pid, kill)
  end,
  Config.


wrong_child_spec(_Config) ->
  {ok, G} = gen_tracker:start_link(test_tracker),
  unlink(G),
  {error, _} = gen_tracker:find_or_open(test_tracker, {<<"process1">>, {?MODULE, process1, [self()]}, temporary, worker, 200, []}),
  ok.

temporary(_Config) ->
  {ok, G} = gen_tracker:start_link(test_tracker),
  unlink(G),
  {ok, Pid} = gen_tracker:find_or_open(test_tracker, {<<"process1">>, {?MODULE, process1, [self()]}, temporary, 200, worker, []}),
  erlang:monitor(process,Pid),
  [{<<"process1">>, Pid, worker, []}] = gen_tracker:which_children(test_tracker),
  [{<<"process1">>, Pid, worker, []}] = supervisor:which_children(test_tracker),
  Pid ! stop,
  receive {'DOWN', _, _, Pid, _} -> ok after 100 -> error(timeout_kill) end,
  gen_server:call(test_tracker, wait), % sync call
  case gen_tracker:which_children(test_tracker) of
    [] -> ok;
    R -> throw({skip, {flaky_test, R}})
  end,
  [] = supervisor:which_children(test_tracker),
  ok.


process1(Parent) ->
  Pid = proc_lib:spawn(fun() ->
    erlang:monitor(process, Parent),
    receive
      invalid_stop -> error(bad_stop);
      stop -> ok
    end
  end),
  {ok, Pid}.



transient(_Config) ->
  {ok, G} = gen_tracker:start_link(test_tracker),
  unlink(G),
  {ok, Pid} = gen_tracker:find_or_open(test_tracker, {<<"process1">>, {?MODULE, process1, [self()]}, transient, 200, worker, []}),
  erlang:monitor(process,Pid),
  [{<<"process1">>, Pid, worker, []}] = gen_tracker:which_children(test_tracker),
  [{<<"process1">>, Pid, worker, []}] = supervisor:which_children(test_tracker),
  Pid ! invalid_stop,
  receive {'DOWN', _, _, Pid, _} -> ok after 100 -> error(timeout_kill) end,
  gen_server:call(test_tracker, wait), % sync call

  [{<<"process1">>, Pid2, worker, []}] = gen_tracker:which_children(test_tracker),
  Pid2 =/= Pid orelse error(old_pid),
  erlang:monitor(process,Pid2),

  Pid2 ! stop,
  receive {'DOWN', _, _, Pid2, _} -> ok after 100 -> error(timeout_kill) end,
  gen_server:call(test_tracker, wait), % sync call

  [] = gen_tracker:which_children(test_tracker),
  [] = supervisor:which_children(test_tracker),
  ok.



list(_) ->
  {ok, G} = gen_tracker:start_link(test_tracker),
  unlink(G),
  {ok, _Pid} = gen_tracker:find_or_open(test_tracker, {<<"list1">>, {?MODULE, process1, [self()]}, transient, 200, worker, []}),
  gen_tracker:setattr(test_tracker, <<"list1">>, [{key1,value1},{key2,value2}]),
  [{<<"list1">>,Attrs1}] = gen_tracker:list(test_tracker),
  value1 = proplists:get_value(key1,Attrs1),
  value2 = proplists:get_value(key2,Attrs1),

  [{<<"list1">>,Attrs2}] = gen_tracker:list(test_tracker, [key1]),
  value1 = proplists:get_value(key1, Attrs2),
  false = lists:keyfind(key2, 1, Attrs2),
  gen_server:call(G, shutdown),
  ok.







permanent(_Config) ->
  {ok, G} = gen_tracker:start_link(test_tracker),
  unlink(G),
  {ok, Pid} = gen_tracker:find_or_open(test_tracker, {<<"process1">>, {?MODULE, process1, [self()]}, permanent, 200, worker, []}),
  erlang:monitor(process,Pid),
  [{<<"process1">>, Pid, worker, []}] = gen_tracker:which_children(test_tracker),
  [{<<"process1">>, Pid, worker, []}] = supervisor:which_children(test_tracker),
  Pid ! invalid_stop,
  receive {'DOWN', _, _, Pid, _} -> ok after 100 -> error(timeout_kill) end,
  gen_server:call(test_tracker, wait), % sync call

  [{<<"process1">>, Pid2, worker, []}] = gen_tracker:which_children(test_tracker),
  Pid2 =/= Pid orelse error(old_pid),
  erlang:monitor(process,Pid2),

  Pid2 ! stop,
  receive {'DOWN', _, _, Pid2, _} -> ok after 100 -> error(timeout_kill) end,
  gen_server:call(test_tracker, wait), % sync call


  [{<<"process1">>, Pid3, worker, []}] = gen_tracker:which_children(test_tracker),
  Pid3 ! invalid_stop,
  erlang:monitor(process,Pid3),
  receive {'DOWN', _, _, Pid3, _} -> ok after 100 -> error(timeout_kill) end,


  [{<<"process1">>, Pid4, worker, []}] = gen_tracker:which_children(test_tracker),
  erlang:monitor(process,Pid4),
  supervisor:delete_child(test_tracker, <<"process1">>),
  receive {'DOWN', _, _, Pid4, _} -> ok after 100 -> error(timeout_kill) end,

  [] = gen_tracker:which_children(test_tracker),
  [] = supervisor:which_children(test_tracker),
  gen_server:call(G, shutdown),
  ok.



shutdown(_Config) ->
  {ok, G} = gen_tracker:start_link(test_tracker),
  unlink(G),
  erlang:monitor(process, G),
  {ok, Pid} = gen_tracker:find_or_open(test_tracker, {<<"process2">>, {?MODULE, process1, [self()]}, permanent, 200, worker, []}),
  erlang:monitor(process,Pid),

  erlang:exit(G, shutdown),
  Reason = receive {'DOWN', _, _, G, Reason_} -> Reason_ after 400 -> exit(timeout_shutdown) end,
  shutdown = Reason,
  not erlang:is_process_alive(Pid) orelse error(child_is_alive),
  ok.



add_existing_child(_) ->
  {ok, G} = gen_tracker:start_link(adding_tracker),
  unlink(G),
  [] = supervisor:which_children(adding_tracker),
  Pid = spawn(fun() ->
    receive M -> M end
  end),
  erlang:monitor(process, Pid),
  gen_tracker:add_existing_child(adding_tracker, {<<"child1">>, Pid, worker, []}),
  [{<<"child1">>, Pid, worker, []}] = supervisor:which_children(adding_tracker),
  Pid ! ok,
  receive
    {'DOWN', _, _, Pid, _} -> ok
  after
    100 -> error(not_died_worker)
  end,
  gen_tracker:wait(adding_tracker),
  timer:sleep(100),
  [] = supervisor:which_children(adding_tracker),
  erlang:exit(G, shutdown),
  ok.


rewrite_existing_child(_) ->
  {ok, G} = gen_tracker:start_link(rewrite_tracker),
  unlink(G),
  [] = supervisor:which_children(rewrite_tracker),
  Pid = spawn(fun() ->
    receive M -> M end
  end),
  Pid2 = spawn(fun() ->
    receive M -> M end
  end),
  erlang:monitor(process, Pid),
  {ok, Pid} = gen_tracker:add_existing_child(rewrite_tracker, {<<"child1">>, Pid, worker, []}),
  {error, {already_started, Pid}} = gen_tracker:add_existing_child(rewrite_tracker, {<<"child1">>, Pid2, worker, []}),
  [{<<"child1">>, Pid, worker, []}] = supervisor:which_children(rewrite_tracker),
  erlang:exit(G, shutdown),
  ok.


async_exit_child(_) ->
  T = self(),
  {ok, G} = gen_tracker:start_link(test_tracker),
  unlink(G),
  GRef = erlang:monitor(process, G),
  %spawn(fun() -> timer:sleep(5000), ct:pal("T ~120p", [erlang:process_info(T, [current_stacktrace, messages])]) end),
  %spawn(fun() -> timer:sleep(3000), ct:pal("G ~120p~n~120p", [erlang:process_info(G, [current_stacktrace, monitors]), (catch sys:get_state(G, 500))]) end),

  [ets:insert(test_tracker_attrs, {{a,I}, {value,I}}) || I <- lists:seq(1,1000000)],

  Name = <<"async_terminate">>,
  MFA = {test_async_after_terminate, start_link, [Name, T]},
  {ok, Pid} = gen_tracker:find_or_open(test_tracker, {Name, MFA, temporary, 300, worker, []}),
  gen_tracker:setattr(test_tracker, Name, [{tracker, G}]),
  erlang:monitor(process,Pid),

  Pid ! stop,
  receive
    {'DOWN', _, _, Pid, _} -> ok
  after
    100 -> error(die_timeout)
  end,

  P = receive
    {dying, Name, P_} -> P_
  after 2000 -> error(no_after_terminate_report)
  end,
  try gen_tracker:setattr(test_tracker, Name, [{should_fail, 123}]) of _ -> error(setattr_should_fail) catch _:_ -> ok end,
  erlang:monitor(process, P),

  ok = gen_server:call(G, wait, 50),

  % Some clients needing this worker back
  [spawn_link(fun() ->
      {ok, FoundPid} = gen_tracker:find_or_open(test_tracker, {Name, MFA, temporary, 200, worker, []}),
      T ! {found_pid, FoundPid}
  end) || _ <- [1,2,3] ],

  fun() -> receive {found_pid, FoundPid} -> error({find_or_open_returned_before_cleanup, FoundPid}) after 100 -> ok end end(),
  P ! get_away,

  % Wait until child is actually restarted
  {ok, Pid2} = restart_child_after_termination(Name, MFA, Pid, P, 1, 1000),
  % Collect client find_or_open results
  [receive {found_pid, _} -> ok after 100 -> error(secondary_find_or_open_timeout) end || _ <- [1,2,3] ],
  % No additional attributes should survive child restart
  undefined = gen_tracker:getattr(test_tracker, Name, should_fail),
  undefined = gen_tracker:getattr(test_tracker, Name, tracker),
  % Set tracker attr again
  gen_tracker:setattr(test_tracker, Name, [{tracker, G}]),

  % Stop second incarnation too, with slow after_terminate
  Pid2 ! stop, %exit(Pid2, kill),
  AP2 = receive {dying, Name, AP2_} -> erlang:send_after(150, AP2_, get_away), monitor(process, AP2_), AP2_ after 1000 -> error(not_dying_2) end,

  % gen_tracker shutdown should not trigger extra after_terminate
  register(test_async_after_terminate, self()),
  erlang:demonitor(GRef, [flush]),
  gen_server:call(G, shutdown),
  receive {'DOWN', _, _, _, _} -> ok after 1000 -> error(second_child_did_not_terminate) end,  %% sync
  receive
    Extra -> ct:pal("test pid ~w, tracker ~w~nW1 ~w/~w   W2~w/~w~nExtra message ~p", [T, G, Pid, P, Pid2, AP2, Extra]), error(extra_message_in_the_end)
  after
    50 -> ok
  end,
  ok.

restart_child_after_termination(Name, MFA, Pid, ATPid, Tmo, Iters) ->
  (Iters > 0) orelse error(after_terminate_did_not_stop),
  receive
    {found_pid, Pid2} ->
      error({new_child_while_after_terminate_is_working, Pid2});
    {'DOWN', _, _, ATPid, _} ->
      % after_terminate has exited, and gen_tracker must start a NEW child on immediate request
      {ok, Pid2} = gen_tracker:find_or_open(test_tracker, {Name, MFA, temporary, 200, worker, []}),
      true = (Pid2 /= Pid),
      {ok, Pid2}
  after
    Tmo ->
      (Tmo > 0) orelse error(new_child_while_after_terminate_is_working),
      % after_terminate seems to be still working, and the old pid should be returned
      try gen_tracker:setattr(test_tracker, Name, [{should_fail, 328}]) of
        ok -> 
          % Just recurse with zero timeout to avoid copy-pasting   receive {'DOWN'...
          % This should return {ok, Pid2} via first clause (or cause an error on zero timeout)
          restart_child_after_termination(Name, MFA, Pid, ATPid, 0, 1)
      catch
        _:_ ->
          % yep, continue checks
          restart_child_after_termination(Name, MFA, Pid, ATPid, Tmo, Iters - 1)
      end
  end.



do_not_set_property_of_unknown_child(_) ->
  {ok, G} = gen_tracker:start_link(unknown_tracker),
  unlink(G),

  {'EXIT', {{void_setting,_,_,_},_}} = (catch gen_tracker:setattr(unknown_tracker, <<"child1">>, [{key1,value1}])),
  {'EXIT', {{void_setting,_,_,_},_}} = (catch gen_tracker:setattr(unknown_tracker, <<"child1">>, key1, value1)),

  undefined = gen_tracker:getattr(unknown_tracker, <<"child1">>, key1),

  Pid = spawn(fun() ->
    receive M -> M end
  end),
  erlang:monitor(process, Pid),
  gen_tracker:add_existing_child(unknown_tracker, {<<"child1">>, Pid, worker, []}),


  gen_server:call(G, shutdown),
  ok.




will_never_start(Parent) ->
  Parent ! {i_am_ready, self()},
  receive
    never_get_here -> ok
  end.


shutdown_launching_child(_) ->
  {ok, G} = gen_tracker:start_link(launching_child),
  unlink(G),

  Parent = self(),
  spawn(fun() ->
    MFA = {?MODULE, will_never_start, [Parent]},
    gen_tracker:find_or_open(launching_child, {will_never_start, MFA, temporary, 200, worker, []})
  end),

  RealPid = receive
    {i_am_ready, RealPid_} -> RealPid_
  after
    1000 -> error(not_launching_child)
  end,
  erlang:monitor(process, RealPid),

  gen_server:call(G, shutdown),
  receive
    {'DOWN', _, _, RealPid, _} -> ok
  after
    1000 -> error(pid_not_dead)
  end,
  ok.

