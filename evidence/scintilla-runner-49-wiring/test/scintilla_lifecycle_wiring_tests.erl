-module(scintilla_lifecycle_wiring_tests).

-include_lib("eunit/include/eunit.hrl").

invocation_holds_admission_until_work_returns_test() ->
    with_lifecycle(fun() ->
        Parent = self(),
        Worker = spawn(fun() ->
            Parent ! {invocation_result, self(),
                lambda_invocation_observer:invoke(cmd, fn_id, payload, 10, 1000)}
        end),
        receive
            {telemetry_entered, Worker, invoke} -> ok
        after 1000 ->
            error(invocation_did_not_reach_telemetry)
        end,
        ?assertEqual(1, maps:get(in_flight, lambda_host_lifecycle:status())),
        Worker ! continue,
        receive
            {invocation_result, Worker, {ok, invoke}} -> ok
        after 1000 ->
            error(invocation_did_not_return)
        end,
        await_in_flight(0, 100)
    end).

actor_invoke_holds_admission_until_work_returns_test() ->
    with_lifecycle(fun() ->
        Parent = self(),
        Worker = spawn(fun() ->
            Parent ! {actor_result, self(),
                lambda_actor_lifecycle:invoke(cmd, fn_id, actor_key, payload, 10, 1000)}
        end),
        receive
            {actor_entered, Worker, invoke} -> ok
        after 1000 ->
            error(actor_did_not_reach_manager)
        end,
        ?assertEqual(1, maps:get(in_flight, lambda_host_lifecycle:status())),
        Worker ! continue,
        receive
            {actor_result, Worker, {ok, invoke}} -> ok
        after 1000 ->
            error(actor_did_not_return)
        end,
        await_in_flight(0, 100)
    end).

sealed_runtime_blocks_invocation_before_telemetry_test() ->
    with_lifecycle(fun() ->
        {ok, Handle} = lambda_host_lifecycle:quiesce(100),
        ?assertEqual(
            {error, <<"runtime lifecycle is sealed for host suspension">>},
            lambda_invocation_observer:invoke(cmd, fn_id, payload, 10, 1000)
        ),
        receive
            {telemetry_entered, _Pid, _Kind} ->
                error(sealed_invocation_reached_telemetry)
        after 50 ->
            ok
        end,
        ok = lambda_host_lifecycle:resume(Handle)
    end).

sealed_runtime_blocks_actor_before_manager_test() ->
    with_lifecycle(fun() ->
        {ok, Handle} = lambda_host_lifecycle:quiesce(100),
        ?assertEqual(
            {error, <<"runtime lifecycle is sealed for host suspension">>},
            lambda_actor_lifecycle:reset(fn_id, actor_key)
        ),
        receive
            {actor_entered, _Pid, _Kind} ->
                error(sealed_actor_reached_manager)
        after 50 ->
            ok
        end,
        ok = lambda_host_lifecycle:resume(Handle)
    end).

runtime_supervisor_contains_lifecycle_authorities_test() ->
    {ok, {_Flags, Children}} = lambda_runtime_supervisor:init(root),
    Ids = [maps:get(id, Child) || Child <- Children],
    ?assert(lists:member(host_lifecycle, Ids)),
    ?assert(lists:member(host_lifecycle_socket, Ids)),
    Lifecycle = hd([Child || Child <- Children, maps:get(id, Child) =:= host_lifecycle]),
    Socket = hd([Child || Child <- Children, maps:get(id, Child) =:= host_lifecycle_socket]),
    ?assertEqual(permanent, maps:get(restart, Lifecycle)),
    ?assertEqual(permanent, maps:get(restart, Socket)).

with_lifecycle(Test) ->
    cleanup(),
    true = register(wiring_probe, self()),
    {ok, Lifecycle} = lambda_host_lifecycle:start_link(),
    unlink(Lifecycle),
    try
        Test()
    after
        cleanup()
    end.

await_in_flight(Expected, 0) ->
    ?assertEqual(Expected, maps:get(in_flight, lambda_host_lifecycle:status()));
await_in_flight(Expected, Attempts) ->
    case maps:get(in_flight, lambda_host_lifecycle:status()) of
        Expected -> ok;
        _Other ->
            timer:sleep(5),
            await_in_flight(Expected, Attempts - 1)
    end.

cleanup() ->
    case whereis(wiring_probe) of
        undefined -> ok;
        _ -> unregister(wiring_probe)
    end,
    case whereis(lambda_host_lifecycle) of
        undefined -> ok;
        Lifecycle ->
            exit(Lifecycle, kill),
            await_unregistered(lambda_host_lifecycle, 100)
    end.

await_unregistered(_Name, 0) ->
    ok;
await_unregistered(Name, Attempts) ->
    case whereis(Name) of
        undefined -> ok;
        _Pid ->
            timer:sleep(5),
            await_unregistered(Name, Attempts - 1)
    end.
