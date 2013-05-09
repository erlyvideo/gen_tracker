%% @doc gen_tracker module
%% MIT license.
%%
-module(gen_tracker).
-author('Max Lapshin <max@maxidoors.ru>').

-behaviour(gen_server).
-include_lib("stdlib/include/ms_transform.hrl").
-include_lib("eunit/include/eunit.hrl").


-export([start_link/1, find/2, find_or_open/2, info/2, list/1, setattr/3, setattr/4, getattr/3, getattr/4, increment/4,delattr/3]).
-export([wait/1]).

-export([which_children/1]).

-export([init/1, handle_call/3, handle_cast/2, handle_info/2, terminate/2, code_change/3]).

-record(tracker, {
  zone
}).

-record(entry, {
  name,
  ref,
  mfa,
  restart_type,
  child_type,
  mods,
  restart_timer,
  restart_delay,
  shutdown,
  pid
}).


info(Zone, Name) ->
  ets:select(attr_table(Zone), ets:fun2ms(fun({{N, K}, V}) when N == Name -> {K,V} end)).

setattr(Zone, Name, Attributes) ->
  ets:insert(attr_table(Zone), [{{Name, K}, V} || {K,V} <- Attributes]).

setattr(Zone, Name, Key, Value) ->
  ets:insert(attr_table(Zone), {{Name, Key}, Value}).

getattr(Zone, Name, Key) ->
  case ets:lookup(attr_table(Zone), {Name, Key}) of
    [{_, V}] -> {ok, V};
    [] -> undefined
  end.

getattr(_Zone, _Name, _Key, Timeout) when Timeout < -1000 ->
  undefined;

getattr(Zone, Name, Key, Timeout) ->
  case getattr(Zone, Name, Key) of
    undefined ->
      timer:sleep(1000),
      getattr(Zone, Name, Key, Timeout - 1000);
    Else ->
      Else
  end.  

increment(Zone, Name, Key, Incr) ->
  ets:update_counter(attr_table(Zone), {Name, Key}, Incr).

list(Zone) ->
  [{Name,[{pid,Pid}|info(Zone, Name)]} || #entry{name = Name, pid = Pid} <- ets:tab2list(Zone)].

find(Zone, Name) ->
  case ets:lookup(Zone, Name) of
    [] -> undefined;
    [#entry{pid = Pid}] -> {ok, Pid}
  end.

find_or_open(Zone, {Name, MFA, RestartType}) ->
  find_or_open(Zone, {Name, MFA, RestartType, 200, worker, []});

find_or_open(Zone, {Name, _MFA, _RestartType, _Shutdown, _ChildType, _Mods} = ChildSpec) ->
  try ets:lookup(Zone, Name) of
    [] ->
      case supervisor:check_childspecs([ChildSpec]) of
        ok -> gen_server:call(Zone, {find_or_open, ChildSpec}, 10000);
        Error -> Error
      end;
    [#entry{pid = Pid}] -> {ok, Pid}
  catch
    error:badarg -> {error, gen_tracker_not_started}
  end.

% Sync call to ensure that all messages has been processed
wait(Zone) ->
  gen_server:call(Zone, wait).



start_link(Zone) ->
  gen_server:start_link({local, Zone}, ?MODULE, [Zone], []).


attr_table(Zone) ->
  list_to_atom(atom_to_list(Zone)++"_attrs").










init([Zone]) ->
  process_flag(trap_exit, true),
  ets:new(Zone, [public,named_table,{keypos,#entry.name}, {read_concurrency, true}]),
  ets:new(attr_table(Zone), [public,named_table]),
  {ok, #tracker{zone = Zone}}.


handle_call(wait, _From, Tracker) ->
  {reply, ok, Tracker};

handle_call(which_children, _From, #tracker{zone = Zone} = Tracker) ->
  {reply, which_children(Zone), Tracker};

handle_call({find_or_open, {Name, {M,F,A}, RestartType, Shutdown, ChildType, Mods}}, _From, #tracker{zone = Zone} = Tracker) ->
  case ets:lookup(Zone, Name) of
    [] ->
      try erlang:apply(M,F,A) of
        {ok, Pid} ->
          Ref = erlang:monitor(process,Pid),
          ets:insert(Zone, #entry{name = Name, mfa = {M,F,A}, pid = Pid, restart_type = RestartType, 
            shutdown = Shutdown, child_type = ChildType, mods = Mods, ref = Ref}),
          {reply, {ok,Pid}, Tracker};
        {error, Error} ->
          {reply, {error, Error}, Tracker};
        Error ->
          error_logger:error_msg("Spawn function in gen_tracker ~p~n for name ~240p~n returned error: ~p~n", [Zone, Name, Error]),
          {reply, Error, Tracker}
      catch
        _Class:Error ->
          error_logger:error_msg("Spawn function in gen_tracker ~p~n for name ~240p~n failed with error: ~p~nStacktrace: ~n~p~n", 
            [Zone, Name,Error, erlang:get_stacktrace()]),
          {reply, {error, Error}, Tracker}
      end;  
    [#entry{pid = Pid}] ->
      {reply, {ok, Pid}, Tracker}
  end;

handle_call({delete_child, Name}, _From, #tracker{zone = Zone} = Tracker) ->
  case ets:lookup(Zone, Name) of
    [#entry{pid = Pid, shutdown = Shutdown} = Entry] when is_number(Shutdown) ->
      exit(Pid, shutdown),
      receive
        {'DOWN', _, _, Pid, _Reason} -> ok
      after
        Shutdown -> 
          erlang:exit(Pid, kill),
          receive
            {'DOWN', _,_, Pid,_} -> ok
          end
      end,
      delete_entry(Zone, Entry),
      {reply, ok, Tracker};
    [#entry{pid = Pid, shutdown = brutal_kill} = Entry] ->
      erlang:exit(Pid, kill),
      receive
        {'DOWN', _,_, Pid,_} -> ok
      end,
      delete_entry(Zone, Entry),
      {reply, ok, Tracker};
    [#entry{pid = Pid, shutdown = infinity} = Entry] ->
      erlang:exit(Pid, shutdown),
      receive
        {'DOWN', _,_, Pid,_} -> ok
      end,
      delete_entry(Zone, Entry),
      {reply, ok, Tracker};
    [] ->
      {reply, {error, no_child}, Tracker}
  end;

handle_call(Call, _From, State) ->
  {stop, {unknown_call, Call}, State}.

handle_cast(Cast, State) ->
  {stop, {unknown_cast, Cast}, State}.

handle_info({'DOWN', _, process, Pid, Reason}, #tracker{zone = Zone} = Tracker) ->
  case ets:select(Zone, ets:fun2ms(fun(#entry{pid = P} = Entry) when P == Pid -> Entry end)) of
    [#entry{restart_type = temporary} = Entry] ->
      delete_entry(Zone, Entry);
    [#entry{restart_type = transient} = Entry] when Reason == normal ->
      delete_entry(Zone, Entry);
    [#entry{name = Name, restart_type = transient, mfa = {M,F,A}} = Entry] ->
      try erlang:apply(M,F,A) of
        {ok, NewPid} ->
          NewRef = erlang:monitor(process,NewPid),
          ets:insert(Zone, Entry#entry{pid = NewPid, ref = NewRef});
        {error, Error} ->
          error_logger:error_msg("Failed to restart transient ~s: ~p", [Name, Error]),
          delete_entry(Zone, Entry);
        Error ->
          error_logger:error_msg("Failed to restart transient ~s: ~p", [Name, Error]),
          delete_entry(Zone, Entry)
      catch
        _Class:Error ->
          error_logger:error_msg("Failed to restart transient ~s: ~p", [Name, Error]),
          delete_entry(Zone, Entry)
      end;
    [#entry{name = Name, restart_type = permanent, mfa = {M,F,A}} = Entry] ->
      try erlang:apply(M,F,A) of
        {ok, NewPid} ->
          NewRef = erlang:monitor(process,NewPid),
          ets:insert(Zone, Entry#entry{pid = NewPid, ref = NewRef});
        Error ->
          error_logger:error_msg("Error restarting permanent ~s: ~p", [Name, Error]),          
          restart_later(Zone, Entry)
      catch
        _Class:Error ->
          error_logger:error_msg("Error restarting permanent ~s: ~p", [Name, Error]),          
          restart_later(Zone, Entry)
      end;
    [] ->
      % ?D({unknown_pid_failed,File, ets:tab2list(Zone)})
      ok
  end,
  {noreply, Tracker};


handle_info({'EXIT', _Pid, _Reason}, #tracker{} = Tracker) ->
  {noreply, Tracker};

handle_info(_Msg, State) ->
  {noreply, State}.

terminate(_,#tracker{zone = Zone}) ->
  [begin
    if Shutdown == brutal_kill -> erlang:exit(Pid,kill);
    true ->
      Delay = if Shutdown == infinity -> 5000; is_number(Shutdown) -> Shutdown end,
      erlang:exit(Pid,shutdown),
      receive
        {'DOWN', _, _, Pid, _} -> ok
      after
        Delay -> erlang:exit(Pid,kill)
      end
    end,
    delete_entry(Zone, Entry)
  end || #entry{pid = Pid, shutdown = Shutdown} = Entry <- ets:tab2list(Zone)],
  ok.

code_change(_, State, _) ->
  {ok, State}.


which_children(Zone) ->
  ets:select(Zone, ets:fun2ms(fun(#entry{name = Name, pid = Pid, child_type = CT, mods = Mods}) ->
    {Name, Pid, CT, Mods}
  end)).

restart_later(Zone, #entry{name = Name, restart_timer = OldTimer, restart_delay = OldDelay} = Entry) ->
  case OldTimer of
    undefined -> ok;
    _ -> erlang:cancel_timer(OldTimer)
  end,
  receive
    {restart_child, Name} -> ok
  after
    0 -> ok
  end,
  Delay = if 
    OldDelay == undefined -> 50;
    OldDelay > 5000 -> 50;
    true -> OldDelay + 150
  end,
  Timer = erlang:send_after(Delay, self(), {restart_child, Name}),
  ets:insert(Zone, Entry#entry{restart_timer = Timer, restart_delay = Delay}),
  ok.



delattr(Zone,Name,Value) ->
  ets:delete(attr_table(Zone),{Name,Value}).

delete_entry(Zone, #entry{name = Name, mfa = {M,_,_}}) ->
  case erlang:function_exported(M, after_terminate, 2) of
    true ->
      Attrs = ets:select(attr_table(Zone), ets:fun2ms(fun({{N, K}, V}) when N == Name -> {K,V} end)),
      try M:after_terminate(Name, Attrs)
      catch
        Class:Error ->
          error_logger:info_msg("Error calling ~p:after_terminate(~p,attrs): ~p:~p\n~p\n", [M, Name, Class, Error, erlang:get_stacktrace()])
      end;
    false -> ok
  end,
  ets:select_delete(Zone, ets:fun2ms(fun(#entry{name = N}) when N == Name -> true end)),
  ets:select_delete(attr_table(Zone), ets:fun2ms(fun({{N, _}, _}) when N == Name -> true end)),
  ok.

  
  
