-module(bmscl_lifecycle_carrier_tests).

-include_lib("eunit/include/eunit.hrl").

same_owner_quiesce_resume_test() ->
    with_runtime(fun() ->
        {ok, Handle} = bmscl_runtime:quiesce(100),
        {ok, #{admission := sealed, drain_blockers := 0}} =
            bmscl_runtime:quiesce_status(Handle),
        ok = bmscl_runtime:resume(Handle),
        #{admission := accepting} = bmscl_deployment_manager:status()
    end).

cross_owner_resume_is_rejected_test() ->
    with_runtime(fun() ->
        Parent = self(),
        Owner = spawn(fun() ->
            {ok, Handle} = bmscl_runtime:quiesce(100),
            Parent ! {handle, self(), Handle},
            receive
                resume ->
                    Parent ! {owner_resume, bmscl_runtime:resume(Handle)}
            end
        end),
        Handle = receive
            {handle, Owner, ReceivedHandle} ->
                ReceivedHandle
        after 1000 ->
            error(owner_quiesce_timeout)
        end,
        ?assertEqual({error, invalid_drain}, bmscl_runtime:resume(Handle)),
        Owner ! resume,
        receive
            {owner_resume, ok} ->
                ok
        after 1000 ->
            error(owner_resume_timeout)
        end
    end).

runtime_replacement_invalidates_handle_test() ->
    with_runtime(fun() ->
        {ok, Handle} = bmscl_runtime:quiesce(100),
        replace_runtime_process(),
        ?assertEqual({error, runtime_changed}, bmscl_runtime:resume(Handle))
    end).

quiesce_owner_death_reopens_admission_test() ->
    with_runtime(fun() ->
        Parent = self(),
        Owner = spawn(fun() ->
            {ok, Handle} = bmscl_runtime:quiesce(100),
            Parent ! {sealed, self(), Handle},
            receive stop -> ok end
        end),
        receive
            {sealed, Owner, _Handle} -> ok
        after 1000 ->
            error(owner_quiesce_timeout)
        end,
        exit(Owner, kill),
        await_accepting(100),
        {ok, Handle2} = bmscl_runtime:quiesce(100),
        ok = bmscl_runtime:resume(Handle2)
    end).

socket_protocol_is_strict_test() ->
    ?assertEqual(status, bmscl_host_lifecycle_socket:parse_request_for_test(<<"v1 status\n">>)),
    ?assertEqual(resume, bmscl_host_lifecycle_socket:parse_request_for_test(<<"v1 resume">>)),
    ?assertEqual({quiesce, 0}, bmscl_host_lifecycle_socket:parse_request_for_test(<<"v1 quiesce 0">>)),
    ?assertEqual({quiesce, 300000}, bmscl_host_lifecycle_socket:parse_request_for_test(<<"v1 quiesce 300000">>)),
    ?assertEqual(invalid, bmscl_host_lifecycle_socket:parse_request_for_test(<<"v1 quiesce 300001">>)),
    ?assertEqual(invalid, bmscl_host_lifecycle_socket:parse_request_for_test(<<"v2 status">>)),
    ?assertEqual(invalid, bmscl_host_lifecycle_socket:parse_request_for_test(<<"resume">>)).

socket_path_is_fixed_test() ->
    Expected = "/run/beamscale-lifecycle/control.sock",
    ?assertEqual({enabled, Expected}, bmscl_host_lifecycle_socket:validate_socket_path_for_test(Expected)),
    ?assertEqual({error, invalid_lifecycle_socket_path},
                 bmscl_host_lifecycle_socket:validate_socket_path_for_test("/tmp/tenant.sock")).

socket_peer_credentials_are_fail_closed_test() ->
    Credentials = #{pid => 4242, uid => 1001, gid => 1002},
    Trusted = #{uid => 1001, gid => 1002},
    Binary = <<4242:32/native-signed, 1001:32/native-unsigned, 1002:32/native-unsigned>>,
    ?assertEqual({ok, Credentials},
                 bmscl_host_lifecycle_socket:decode_peer_credentials_for_test(Binary)),
    ?assertEqual(ok,
                 bmscl_host_lifecycle_socket:authorize_peer_for_test(Credentials, Trusted)),
    ?assertEqual({error, unauthorized_peer},
                 bmscl_host_lifecycle_socket:authorize_peer_for_test(
                   Credentials, Trusted#{uid := 1003})),
    ?assertEqual({error, unauthorized_peer},
                 bmscl_host_lifecycle_socket:authorize_peer_for_test(
                   Credentials, Trusted#{gid := 1004})),
    ?assertEqual({error, invalid_peer_credentials},
                 bmscl_host_lifecycle_socket:decode_peer_credentials_for_test(<<0, 1, 2>>)).

with_runtime(Test) ->
    cleanup(),
    {ok, Manager} = bmscl_deployment_manager:start_link(),
    unlink(Manager),
    Runtime = spawn(fun runtime_loop/0),
    true = register(bmscl_runtime_sup, Runtime),
    try
        Test()
    after
        cleanup()
    end.

replace_runtime_process() ->
    Old = whereis(bmscl_runtime_sup),
    true = unregister(bmscl_runtime_sup),
    exit(Old, kill),
    Runtime = spawn(fun runtime_loop/0),
    true = register(bmscl_runtime_sup, Runtime),
    ok.

runtime_loop() ->
    receive
        stop -> ok
    end.

await_accepting(0) ->
    ?assertEqual(accepting, maps:get(admission, bmscl_deployment_manager:status()));
await_accepting(Attempts) ->
    case maps:get(admission, bmscl_deployment_manager:status()) of
        accepting ->
            ok;
        _ ->
            timer:sleep(5),
            await_accepting(Attempts - 1)
    end.

cleanup() ->
    case whereis(bmscl_runtime_sup) of
        undefined -> ok;
        Runtime ->
            unregister(bmscl_runtime_sup),
            exit(Runtime, kill)
    end,
    case whereis(bmscl_deployment_manager) of
        undefined -> ok;
        Manager ->
            exit(Manager, kill),
            await_unregistered(bmscl_deployment_manager, 100)
    end.

await_unregistered(_Name, 0) ->
    ok;
await_unregistered(Name, Attempts) ->
    case whereis(Name) of
        undefined ->
            ok;
        _Pid ->
            timer:sleep(5),
            await_unregistered(Name, Attempts - 1)
    end.
