-module(enough_SUITE).

-export([all/0]).

-export([
    pings_back/1,
    get_pid/1,
    get_ref/1,
    overload/1,
    stopping/1,
    kill_on_choked/1
]).

-include_lib("stdlib/include/assert.hrl").
-include_lib("common_test/include/ct.hrl").
-include_lib("syntax_tools/include/merl.hrl").

all() ->
    [
        pings_back,
        get_pid,
        get_ref,
        overload,
        stopping,
        kill_on_choked
    ].

pings_back(_Config) ->
    Quoted = ?Q([
        "-export([init/1,handle_load/2]).",
        "init(Arg) -> {ok,Arg}.",
        "handle_load({ping,Pid},State) ->",
        "    Pid ! pong,",
        "    State."
    ]),
    {ok, Name, _} = build_module(Quoted),
    {ok, _Pid, OlpRef} = enough:start_link(?FUNCTION_NAME, Name, []),
    enough:load(OlpRef, {ping, self()}),
    receive
        pong -> ok
    after 1000 -> ?assert(false)
    end.

get_pid(_Config) ->
    Quoted = ?Q([
        "-export([init/1,handle_load/2]).",
        "init(Arg) -> {ok,Arg}.",
        "handle_load({ping,Pid},State) ->",
        "    Pid ! pong,",
        "    State."
    ]),
    {ok, Name, _} = build_module(Quoted),
    {ok, Pid, OlpRef} = enough:start_link(?FUNCTION_NAME, Name, []),
    ?assertEqual(Pid, enough:get_pid(OlpRef)).

get_ref(_Config) ->
    Quoted = ?Q([
        "-export([init/1,handle_load/2]).",
        "init(Arg) -> {ok,Arg}.",
        "handle_load(get_ref,Pid) ->",
        "    Pid ! enough:get_ref(),",
        "    Pid."
    ]),
    {ok, Name, _} = build_module(Quoted),
    {ok, Pid, OlpRef} = enough:start_link(?FUNCTION_NAME, Name, self()),
    ?assertEqual({ok, OlpRef}, enough:get_ref(Pid)),
    enough:load(OlpRef, get_ref),
    receive
        OlpRef -> ok
    after 1000 -> ?assert(false)
    end.

overload(_Config) ->
    Quoted = ?Q([
        "-export([init/1,handle_load/2]).",
        "init(Arg) -> {ok,Arg}.",
        "handle_load(ping,Pid) -> Pid."
    ]),
    {ok, Name, _} = build_module(Quoted),
    {ok, Pid, OlpRef} = enough:start_link(?FUNCTION_NAME, Name, self(), #{
        sync_mode_qlen => 1,
        drop_mode_qlen => 10
    }),
    sys:suspend(Pid),
    [enough:load(OlpRef, ping) || _ <- lists:seq(0, 20)],
    sys:resume(Pid),
    enough:load(OlpRef, ping),
    #{casts := Casts, drops := Drops} = enough:info(OlpRef),
    ?assert(Casts >= 1),
    ?assert(Drops >= 1).

stopping(_Config) ->
    Quoted = ?Q([
        "-export([init/1,handle_load/2]).",
        "init(Arg) -> {ok,Arg}.",
        "handle_load(ping,State) ->",
        "    State."
    ]),
    {ok, Name, _} = build_module(Quoted),
    ct:log("By PID"),
    {ok, Pid1, _OlpRef1} = enough:start(?FUNCTION_NAME, Name, []),
    ?assert(erlang:is_process_alive(Pid1)),
    ok = enough:stop(Pid1),
    ?assertNot(erlang:is_process_alive(Pid1)),
    ct:log("By OLP ref"),
    {ok, Pid2, OlpRef2} = enough:start(?FUNCTION_NAME, Name, []),
    ?assert(erlang:is_process_alive(Pid2)),
    ok = enough:stop(OlpRef2),
    ?assertNot(erlang:is_process_alive(Pid2)).

kill_on_choked(_Config) ->
    Quoted = ?Q([
        "-export([init/1,handle_load/2]).",
        "init(Arg) -> {ok,Arg}.",
        "handle_load(_Msg,State) ->",
        "    State."
    ]),
    {ok, Name, _} = build_module(Quoted),
    {ok, Pid, OlpRef} = enough:start_link(?FUNCTION_NAME, Name, [], #{
        overload_kill_enable => true,
        overload_kill_qlen => 2,
        overload_kill_restart_after => infinity
    }),
    erlang:process_flag(trap_exit, true),
    sys:suspend(Pid),
    [enough:load(OlpRef, ping) || _ <- lists:seq(0, 10)],
    sys:resume(Pid),
    enough:load(OlpRef, ping),
    receive
        Msg -> ?assertMatch({'EXIT', Pid, {shutdown, {overloaded, _, _}}}, Msg)
    after 100 -> ?assert(false)
    end.

build_module(Content) ->
    Name = erlang:binary_to_atom(
        list_to_binary(io_lib:format("enough_module_~B", [erlang:unique_integer([positive])])),
        utf8
    ),
    Quoted = [?Q("-module('@Name@').") | Content],
    {ok, Binary} = merl:compile_and_load(Quoted),
    {ok, Name, Binary}.
