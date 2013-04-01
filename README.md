gen_tracker
-----------

This is an erlang library that allows you to use supervisor with keeping process names and their metadata in ets.

MIT license. Use as you wish, don't remove copyrights


Usage
=====


Include new supervisor in your application:

    flussonic_sup.erl:
    
    init([]) ->
      Supervisors = [{streams, {gen_tracker, start_link, [streams]}, permanent, infinity, supervisor, []}],
      {ok, { {one_for_one, 5, 10}, Supervisors} }.

Now gen_tracker instance is started and ets tables 'streams' and 'streams_attrs' are created. Be sure that this name doesn't mess with anything.
Also this gen_tracker instance automatically registers itself as a 'streams' process. It is a good idea,
because table 'streams' is created as a public,named_table so it is already a singleton.


Now comes process adding:

    Stream = {<<"tv1">>, {stream, start_link, [<<"tv1">>, Options]}, temporary, infinity, supervisor, []},
    {ok, Pid} = gen_tracker:find_or_open(streams, Stream).


gen_tracker instance called 'streams' atomically either find existing child with name <<"tv1">>, either creates
new instance and registeres it in table 'streams'.


Now you can find it:

    {ok, Pid} = gen_tracker:find(streams, <<"tv1">>).


This function call doesn't make any gen_server:call to any process, only ets table lookup is performed

Now let's work with metadata. Process launched under gen_tracker can save some metadata outside itself so
that any other process can access it without making blocking and expensive gen_server:call:

    gen_tracker:setattr(streams, Name, [{hds,true},{bytes_in,0},{bytes_out,0}]),
    gen_tracker:increment(streams, Name, bytes_in, 1000),
    {ok, BytesIn} = gen_tracker:getattr(streams, Name, bytes_in).

Now let's be sure that gen_tracker instance is a supervisor:

    supervisor:which_children(streams),
    supervisor:delete_child(streams, <<"tv1">>).



