%% @doc gen_tracker module
%% MIT license.
%%
-module(gen_tracker).
-author('Max Lapshin <max@maxidoors.ru>').

-behaviour(gen_server).
-include_lib("stdlib/include/ms_transform.hrl").
-include_lib("kernel/include/logger.hrl").


-export([start_link/1, find/2, find_or_open/2, info/2, list/1, setattr/3, setattr/4, getattr/3, getattr/4, increment/4,increment/5,delattr/3]).
-export([attrs/2]).
-export([wait/1]).
-export([list/2, info/3]).
-export([init_ack/1]).

-export([which_children/1]).
-export([add_existing_child/2]).
-export([child_monitoring/4]).

-export([init/1, handle_call/3, handle_cast/2, handle_info/2, terminate/2, code_change/3]).

-export([init_setter/1]).

-record(tracker, {
  zone,
  launchers = []
}).

-record(launch, {
  name,
  spec,
  pid,
  ref,
  waiters = []
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
  sub_pid,
  pid
}).


info(Zone, Name) ->
  ets:select(attr_table(Zone), ets:fun2ms(fun({{N, K}, V}) when N == Name -> {K,V} end)).


% Name == <<"aa">>
% ets:fun2ms(fun({{N, K}, V}) when N == Name andalso (K == <<"key">> orelse K == key2) -> {K,V} end).
% [{  
%   {{'$1','$2'},'$3'},
%
%   [{'andalso',{'==','$1',{const,<<"aa">>}},
%               {'orelse',{'==','$2',<<"key">>},{'==','$2',key2}}}],
%
%   [{{'$2','$3'}}]
% }]

info(_Zone, _Name, []) ->
  [];

info(Zone, Name, Keys) ->
  Head = {{'$1','$2'},'$3'},
  Output = [{{'$2','$3'}}],

  KeyCond = case Keys of
    {ms, Keys0} -> Keys0;
    _ -> build_key_condition(Keys)
  end,
  Cond = [{'andalso',{'==', '$1', Name}, KeyCond }],
  MS = [{Head, Cond, Output}],
  ets:select(attr_table(Zone), MS).


build_key_condition([Key]) -> {'==', '$2', Key};
build_key_condition([Key|Keys]) -> {'orelse', {'==', '$2', Key}, build_key_condition(Keys)}.



setattr(Zone, Name, Attributes) ->
  % ets:insert(attr_table(Zone), [{{Name, K}, V} || {K,V} <- Attributes]).
  ok == gen_server:call(attr_process(Zone), {set, Name, Attributes}) orelse error({void_setting,Zone,Name,[K || {K,_} <- Attributes]}),
  ok.

setattr(Zone, Name, Key, Value) ->
  % ets:insert(attr_table(Zone), {{Name, Key}, Value}).
  ok == gen_server:call(attr_process(Zone), {set, Name, Key, Value}) orelse error({void_setting,Zone,Name,Key}),
  ok.

delattr(Zone,Name,Key) ->
  % ets:delete(attr_table(Zone),{Name,Key}).
  gen_server:call(attr_process(Zone), {delete, Name, Key}).


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

attrs(Zone, Name) ->
  Attrs = ets:select(attr_table(Zone), ets:fun2ms(fun({{N, K}, V}) when N == Name -> {K,V} end)),
  Attrs.


increment(Zone, Name, Key, Incr) ->
  ets:update_counter(attr_table(Zone), {Name, Key}, Incr).

increment(Zone, Name, Key, Incr, Default) ->
  ets:update_counter(attr_table(Zone), {Name, Key}, Incr, {{Name, Key}, Default}).

list(Zone) ->
  [{Name,[{pid,Pid}|info(Zone, Name)]} || #entry{name = Name, pid = Pid} <- ets:tab2list(Zone), is_pid(Pid)].


list(Zone, []) ->
  [{Name,[{pid,Pid}]} || #entry{name = Name, pid = Pid} <- ets:tab2list(Zone), is_pid(Pid)];

list(Zone, Keys) ->
  KeysMS = {ms, build_key_condition(Keys)},
  [{Name,[{pid,Pid}|info(Zone, Name, KeysMS)]} || #entry{name = Name, pid = Pid} <- ets:tab2list(Zone), is_pid(Pid)].




find(Zone, Name) ->
  case ets:lookup(Zone, Name) of
    [] -> undefined;
    [#entry{pid = launching}] -> undefined;
    [#entry{pid = terminating}] -> undefined;
    [#entry{pid = Pid}] when is_pid(Pid) -> {ok, Pid}
  end.

find_or_open(Zone, {Name, MFA, RestartType}) ->
  find_or_open(Zone, {Name, MFA, RestartType, 200, worker, []});

find_or_open(Zone, {Name, _MFA, _RestartType, _Shutdown, _ChildType, _Mods} = ChildSpec) ->
  try ets:lookup(Zone, Name) of
    [#entry{pid = Pid}] when is_pid(Pid) ->
      {ok, Pid};
    _ ->
      case supervisor:check_childspecs([ChildSpec]) of
        ok -> gen_server:call(Zone, {find_or_open, ChildSpec}, 60000);
        Error -> Error
      end
  catch
    error:badarg -> {error, gen_tracker_not_started}
  end.

% Sync call to ensure that all messages has been processed
wait(Zone) ->
  gen_server:call(Zone, wait).


init_ack(Ret) ->
  [Launcher|_] = get('$ancestors'),
  proc_lib:init_ack(Ret),
  gen_server:call(Launcher, wait).



add_existing_child(Tracker, {_Name, Pid, worker, _} = ChildSpec) when is_pid(Pid) ->
  gen_server:call(Tracker, {add_existing_child, ChildSpec}).

start_link(Zone) ->
  gen_server:start_link({local, Zone}, ?MODULE, [Zone], [{spawn_opt,[{fullsweep_after,1}]}]).


attr_table(live_streams) -> live_streams_attrs;
attr_table(vod_files) -> vod_files_attrs;
attr_table(Zone) ->
  list_to_atom(atom_to_list(Zone)++"_attrs").


attr_process(live_streams) -> live_streams_setter;
attr_process(vod_files) -> vod_files_setter;
attr_process(Zone) ->
  list_to_atom(atom_to_list(Zone)++"_setter").








init([Zone]) ->
  process_flag(trap_exit, true),
  ets:new(Zone, [public,named_table,{keypos,#entry.name}, {read_concurrency, true}]),
  ets:new(attr_table(Zone), [public,named_table, {read_concurrency, true}]),

  proc_lib:start_link(?MODULE, init_setter, [Zone]),
  {ok, #tracker{zone = Zone}}.


init_setter(Zone) ->
  erlang:register(attr_process(Zone), self()),
  proc_lib:init_ack({ok, self()}),
  put(name, {setter, Zone}),
  loop_setter(Zone, attr_table(Zone)).

loop_setter(Zone, Table) ->
  Msg = receive M -> M end,
  case Msg of
    {'$gen_call', From, Call} ->
      {ok, Reply} = handle_setter_call(Call, Zone, Table),
      gen:reply(From, Reply),
      loop_setter(Zone, Table);
    Else ->
      ?LOG_INFO(#{unknown_msg => Else, table => Table, zone => Zone}),
      loop_setter(Zone, Table)
  end.


handle_setter_call({set, Name, Key, Value}, Zone, Table) ->
  case ets:lookup(Zone, Name) of
    [#entry{pid = Pid}] when is_pid(Pid); Pid == launching ->
      ets:insert(Table, {{Name, Key}, Value}),
      {ok, ok};
    _ ->
      {ok, {error, enoent}}
  end;

handle_setter_call({set, Name, Attributes}, Zone, Table) ->
  case ets:lookup(Zone, Name) of
    [#entry{pid = Pid}] when is_pid(Pid); Pid == launching ->
      ets:insert(Table, [{{Name, K}, V} || {K,V} <- Attributes]),
      {ok, ok};
    _ ->
      {ok, {error, enoent}}
  end;

handle_setter_call({delete, Name, Key}, _Zone, Table) ->
  ets:delete(Table, {Name, Key}),
  {ok, ok}.




launch_child(Zone, {Name, {M,F,A}, RestartType, Shutdown, ChildType, Mods}) ->
  Parent = self(),
  proc_lib:spawn_link(fun() ->
    put(name, {gen_tracker,Zone,proxy,Name}),
    process_flag(trap_exit,true),
    ets:insert(Zone, #entry{
        name = Name, mfa = {M,F,A}, restart_type = RestartType, shutdown = Shutdown, child_type = ChildType, mods = Mods,
        pid = launching, sub_pid = self()
    }),
    try erlang:apply(M,F,A) of
      {ok, Pid} ->
        ets:update_element(Zone, Name, {#entry.pid, Pid}),
        gen_server:call(Parent, {launch_ready, self(), Name, {ok, Pid}}, 30000),
        erlang:monitor(process,Pid),
        proc_lib:hibernate(?MODULE, child_monitoring, [Zone, Name, Pid, Parent]);
      {error, Error} ->
        ets:delete(Zone, Name),
        Parent ! {launch_ready, self(), Name, {error, Error}};
      Error ->
        ets:delete(Zone, Name),
        ?LOG_ERROR(#{zone => Zone, name => Name, spawn_error => Error}),
        Parent ! {launch_ready, self(), Name, Error}
    catch
      _Class:Error:Stack ->
        ets:delete(Zone, Name),
        ?LOG_ERROR(#{zone => Zone, name => Name, spawn_error => Error, stacktrace => Stack}),
        Parent ! {launch_ready, self(), Name, {error, Error}}
    end 
  end).


child_monitoring(Zone, Name, Pid, Parent) ->
  receive
    M ->
      case M of
        {'$gen_call', From, wait} ->
          gen:reply(From, ok);
        {'EXIT', Parent, Reason} ->
          catch cleanup_from_parent_death(Zone, Name, Reason),
          exit(Pid, Reason),
          receive
            {'DOWN', _, _, Pid, _} -> ok
          after
            5000 -> ok
          end,
          exit(Reason);
        {'DOWN', _, _, Pid, Reason} ->
          catch cleanup_from_child_death(Zone, Name, Reason),
          exit(normal);
        _ -> ok
      end
  after
    0 -> ok
  end,
  proc_lib:hibernate(?MODULE, child_monitoring, [Zone, Name, Pid, Parent]).


cleanup_from_parent_death(Zone, Name, Reason) ->
  delete_entry(Zone, Name, Reason),
  ok.

cleanup_from_child_death(Zone, Name, Reason) ->
  delete_entry(Zone, Name, Reason),
  ok.



shutdown_children(Scope, Entries, Zone) ->
  MonRefs = [async_shutdown_child(E, Zone) || E <- Entries],
  [receive {'DOWN', R, _, _, _} -> ok end || R <- lists:flatten(MonRefs), is_reference(R)],
  case Scope of
    one ->
      [ets:select_delete(attr_table(Zone), ets:fun2ms(fun({{N, _}, _}) when N == Name -> true end)) || #entry{name = Name} <- Entries],
      [ets:delete(Zone, Name) || #entry{name = Name} <- Entries];
    all ->
      ets:delete_all_objects(attr_table(Zone)),
      ets:delete_all_objects(Zone)
  end,
  ok.

async_shutdown_child(#entry{sub_pid = SubPid, pid = Pid, shutdown = Shutdown}, _Zone) when is_number(Shutdown) ->
  is_pid(Pid) andalso erlang:exit(Pid, shutdown),
  erlang:exit(SubPid, shutdown),
  timer:exit_after(Shutdown, SubPid, kill),
  SubRef = erlang:monitor(process, SubPid),
  WRefs = [begin timer:exit_after(Shutdown, Pid, kill), erlang:monitor(process, Pid) end || is_pid(Pid)],
  [SubRef|WRefs];


async_shutdown_child(#entry{sub_pid = SubPid, pid = Pid, shutdown = brutal_kill}, _Zone) ->
  is_pid(Pid) andalso erlang:exit(Pid, kill),
  timer:exit_after(100, SubPid, kill),          % give it 100 ms for cleanup
  SubRef = erlang:monitor(process, SubPid),
  [SubRef];

async_shutdown_child(#entry{sub_pid = SubPid, pid = Pid, shutdown = infinity}, _Zone) ->
  erlang:exit(SubPid, shutdown),
  is_pid(Pid) andalso erlang:exit(Pid, shutdown),
  SubRef = erlang:monitor(process, SubPid),
  WRefs = [erlang:monitor(process, Pid) || is_pid(Pid)],
  [SubRef|WRefs].




handle_call(wait, _From, Tracker) ->
  {reply, ok, Tracker};

handle_call(shutdown, _From, #tracker{zone = Zone} = Tracker) ->
  shutdown_children(all, ets:tab2list(Zone), Zone),
  {stop, shutdown, ok, Tracker};

handle_call(which_children, _From, #tracker{zone = Zone} = Tracker) ->
  {reply, which_children(Zone), Tracker};

handle_call({find_or_open, {Name, {_,_,_}, _RT, _S, _CT, _M} = Spec}, From, #tracker{zone = Zone, launchers = Launchers} = Tracker) ->
  case ets:lookup(Zone, Name) of
    [#entry{pid = Pid}] when is_pid(Pid) ->
      {reply, {ok, Pid}, Tracker};
    Other ->
      case lists:keytake(Name, #launch.name, Launchers) of
        {value, #launch{waiters = Waiters} = L, Launchers1} ->
          L1 = L#launch{waiters = [From|Waiters]},
          {noreply, Tracker#tracker{launchers = [L1|Launchers1]}};
        false ->
          {Pid, Action} = case Other of
            [] -> {launch_child(Zone, Spec), error};
            [#entry{sub_pid = LauncherPid}] -> {LauncherPid, restart}
          end,
          Ref = erlang:monitor(process, Pid, [{tag, {launcher_down, Name, Action}}]),
          L = #launch{name = Name, pid = Pid, ref = Ref, spec = Spec, waiters = [From]},
          {noreply, Tracker#tracker{launchers = [L|Launchers]}}
      end
  end;

handle_call({terminate_child, Name}, From, #tracker{} = Tracker) ->
  handle_call({delete_child, Name}, From, Tracker);

handle_call({delete_child, Name}, _From, #tracker{zone = Zone} = Tracker) ->
  case ets:lookup(Zone, Name) of
    [Entry] ->
      shutdown_children(one, [Entry], Zone),
      {reply, ok, Tracker};
    [] ->
      {reply, {error, no_child}, Tracker}
  end;

handle_call({add_existing_child, {Name, Pid, worker, Mods}}, _From, #tracker{zone = Zone} = Tracker) ->
  case ets:lookup(Zone, Name) of
    [#entry{pid = Pid2}] when is_pid(Pid2) ->
      {reply, {error, {already_started, Pid2}}, Tracker};
    [] ->
      Ref = erlang:monitor(process,Pid),
      ets:insert(Zone, #entry{name = Name, mfa = undefined, sub_pid = Pid, pid = Pid, restart_type = temporary,
        shutdown = 200, child_type = worker, mods = Mods, ref = Ref}),

      Parent = self(),
      proc_lib:spawn_link(fun() ->
        put(name, {gen_tracker,Zone,proxy,Name}),
        process_flag(trap_exit,true),
        ets:update_element(Zone, Name, {#entry.sub_pid, self()}),
        erlang:monitor(process,Pid),
        proc_lib:hibernate(?MODULE, child_monitoring, [Zone, Name, Pid, Parent])
      end),
      {reply, {ok, Pid}, Tracker}
  end;

handle_call(stop, _From, #tracker{} = Tracker) ->
  {stop, normal, ok, Tracker};

handle_call({launch_ready, _, _, _} = Msg, From, #tracker{} = Tracker) ->
  gen:reply(From, ok),
  handle_info(Msg, Tracker);

handle_call(Call, _From, State) ->
  {stop, {unknown_call, Call}, State}.

handle_cast(Cast, State) ->
  {stop, {unknown_cast, Cast}, State}.



handle_info({launch_ready, Launcher, Name, Reply}, #tracker{launchers = Launchers} = Tracker) ->
  {value, #launch{pid = Launcher, ref = Ref, name = Name, waiters = Waiters}, Launchers1} =
    lists:keytake(Name, #launch.name, Launchers),
  erlang:demonitor(Ref, [flush]),
  [gen_server:reply(From, Reply) || From <- Waiters],
  % case Reply of
  %   {ok, Pid} ->
  %     R1 = erlang:monitor(process, Pid),
  %     ets:update_element(Zone, Name, {#entry.ref, R1});
  %   _ ->
  %     ok
  % end,
  {noreply, Tracker#tracker{launchers = Launchers1}};


%% If launcher itself crashes, return an error to all clients
handle_info({{launcher_down, Name, error}, _, process, _, Reason}, #tracker{zone = Zone, launchers = Launchers} = Tracker) ->
  {value, #launch{name = Name, waiters = Waiters}, Launchers1} =
    lists:keytake(Name, #launch.name, Launchers),
  ets:select_delete(attr_table(Zone), ets:fun2ms(fun({{N, _}, _}) when N == Name -> true end)),
  ets:delete(Zone, Name),
  Reply = {error, Reason},
  [gen_server:reply(From, Reply) || From <- Waiters],
  {noreply, Tracker#tracker{launchers = Launchers1}};

%% old launcher has finished its work (after_terminate), now it's time to start a new child as clients requested
handle_info({{launcher_down, Name, restart}, _, process, _, _}, #tracker{zone = Zone, launchers = Launchers} = Tracker) ->
  {value, L0, Launchers1} = lists:keytake(Name, #launch.name, Launchers),
  #launch{name = Name, spec = Spec} = L0,
  Pid = launch_child(Zone, Spec),
  Ref = erlang:monitor(process, Pid, [{tag, {launcher_down, Name, error}}]),
  L = L0#launch{pid = Pid, ref = Ref},
  {noreply, Tracker#tracker{launchers = [L|Launchers1]}};


% handle_info({'DOWN', _, process, Pid, Reason}, #tracker{zone = Zone} = Tracker) ->
%   case ets:select(Zone, ets:fun2ms(fun(#entry{pid = P} = Entry) when P == Pid -> Entry end)) of
%     [#entry{restart_type = temporary} = Entry] ->
%       delete_entry(Zone, Entry);
%     [#entry{restart_type = transient} = Entry] when Reason == normal ->
%       delete_entry(Zone, Entry);
%     [#entry{name = Name, restart_type = transient, mfa = {M,F,A}} = Entry] ->
%       try erlang:apply(M,F,A) of
%         {ok, NewPid} ->
%           NewRef = erlang:monitor(process,NewPid),
%           ets:insert(Zone, Entry#entry{pid = NewPid, sub_pid = NewPid, ref = NewRef});
%         {error, Error} ->
%           ?LOG_ERROR("Failed to restart transient ~s: ~p", [Name, Error]),
%           delete_entry(Zone, Entry);
%         Error ->
%           ?LOG_ERROR("Failed to restart transient ~s: ~p", [Name, Error]),
%           delete_entry(Zone, Entry)
%       catch
%         _Class:Error ->
%           ?LOG_ERROR("Failed to restart transient ~s: ~p", [Name, Error]),
%           delete_entry(Zone, Entry)
%       end;
%     [#entry{name = Name, restart_type = permanent, mfa = {M,F,A}} = Entry] ->
%       try erlang:apply(M,F,A) of
%         {ok, NewPid} ->
%           NewRef = erlang:monitor(process,NewPid),
%           ets:insert(Zone, Entry#entry{pid = NewPid, sub_pid = NewPid, ref = NewRef});
%         Error ->
%           ?LOG_ERROR("Error restarting permanent ~s: ~p", [Name, Error]),          
%           restart_later(Zone, Entry)
%       catch
%         _Class:Error ->
%           ?LOG_ERROR("Error restarting permanent ~s: ~p", [Name, Error]),          
%           restart_later(Zone, Entry)
%       end;
%     [] ->
%       ok
%   end,
%   {noreply, Tracker};


handle_info({'EXIT', _Pid, _Reason}, #tracker{} = Tracker) ->
  {noreply, Tracker};

handle_info(_Msg, State) ->
  {noreply, State}.

terminate(_,#tracker{zone = Zone}) ->
  [erlang:exit(SubPid, shutdown) || #entry{sub_pid = SubPid} <- ets:tab2list(Zone)],

  [begin
    erlang:monitor(process, Pid),
    erlang:monitor(process, SubPid),
    if Shutdown == brutal_kill ->
      erlang:exit(SubPid,kill),
      erlang:exit(Pid,kill),
      receive
        {'DOWN', _, _, Pid, _} -> ok
      end,
      receive
        {'DOWN', _, _, SubPid, _} -> ok
      end,
      ok;
    true ->
      Delay = if Shutdown == infinity -> 20000; is_number(Shutdown) -> Shutdown end,
      receive
        {'DOWN', _, _, SubPid, _} -> ok
      after
        Delay -> 
          is_pid(SubPid) andalso erlang:exit(SubPid,kill),
          is_pid(Pid) andalso erlang:exit(Pid,kill),
          receive
            {'DOWN', _, _, Pid, _} -> ok
          end,
          receive
            {'DOWN', _, _, SubPid, _} -> ok
          end
      end
    end
  end || #entry{sub_pid = SubPid, pid = Pid, shutdown = Shutdown} <- ets:tab2list(Zone)],
  ok.

code_change(_, State, _) ->
  {ok, State}.


which_children(Zone) ->
  ets:select(Zone, ets:fun2ms(fun(#entry{name = Name, pid = Pid, child_type = CT, mods = Mods}) ->
    {Name, Pid, CT, Mods}
  end)).

% restart_later(Zone, #entry{name = Name, restart_timer = OldTimer, restart_delay = OldDelay} = Entry) ->
%   case OldTimer of
%     undefined -> ok;
%     _ -> erlang:cancel_timer(OldTimer)
%   end,
%   receive
%     {restart_child, Name} -> ok
%   after
%     0 -> ok
%   end,
%   Delay = if 
%     OldDelay == undefined -> 50;
%     OldDelay > 5000 -> 50;
%     true -> OldDelay + 150
%   end,
%   Timer = erlang:send_after(Delay, self(), {restart_child, Name}),
%   ets:insert(Zone, Entry#entry{restart_timer = Timer, restart_delay = Delay}),
%   ok.






delete_entry(Zone, #entry{name = Name, mfa = undefined}, _) ->
  ets:update_element(Zone, Name, {#entry.pid, terminating}),
  ets:select_delete(attr_table(Zone), ets:fun2ms(fun({{N, _}, _}) when N == Name -> true end)),
  ets:delete(Zone, Name),
  ok;

delete_entry(Zone, #entry{name = Name, mfa = {M,_,_}}, Reason) ->
  ets:update_element(Zone, Name, {#entry.pid, terminating}),
  UseAT3 = erlang:function_exported(M, after_terminate, 3),
  UseAT2 = (not UseAT3) andalso erlang:function_exported(M, after_terminate, 2),
  if
    UseAT3 ->
      Attrs = ets:select(attr_table(Zone), ets:fun2ms(fun({{N, K}, V}) when N == Name -> {K,V} end)),
      put(name, {gen_tracker_after_terminate,Zone,Name}),
      try M:after_terminate(Name, Attrs, Reason)
      catch
        _Class:Error:Stack ->
          ?LOG_INFO(#{zone => Zone, name => Name, after_terminate_error => Error, stacktrace => Stack})
      end;
    UseAT2 ->
      Attrs = ets:select(attr_table(Zone), ets:fun2ms(fun({{N, K}, V}) when N == Name -> {K,V} end)),
      put(name, {gen_tracker_after_terminate,Zone,Name}),
      try M:after_terminate(Name, Attrs)
      catch
        _Class:Error:Stack ->
          ?LOG_INFO(#{zone => Zone, name => Name, after_terminate_error => Error, stacktrace => Stack})
      end;
    true ->
      ok
  end,
  ets:select_delete(attr_table(Zone), ets:fun2ms(fun({{N, _}, _}) when N == Name -> true end)),
  ets:delete(Zone, Name),
  ok;

delete_entry(Zone, Name, Reason) ->
  case ets:lookup(Zone, Name) of
    [#entry{} = E] -> delete_entry(Zone, E, Reason);
    [] -> ok
  end.


