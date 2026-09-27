-module(scintilla_lifecycle_carrier_tests).

-include_lib("eunit/include/eunit.hrl").

quiesce_seals_and_resume_reopens_test() ->
    with_lifecycle(fun() ->
        {ok, Handle} = lambda_host_lifecycle:quiesce(100),
        ?assertMatch({ok, #{admission := sealed, in_flight := 0}},
                     lambda_host_lifecycle:quiesce_status(Handle)),
        ?assertEqual({error, lifecycle_sealed}, lambda_host_lifecycle:request_admission()),
        ok = lambda_host_lifecycle:resume(Handle),
        ?assertEqual(true, lambda_host_lifecycle:ready())
    end).

demand_cancels_quiescing_before_seal_test() ->
    with_lifecycle(fun() ->
        {ok, Admission} = lambda_host_lifecycle:request_admission(),
        Parent = self(),
        Owner = spawn(fun() ->
            Parent ! {quiesce_result, self(), lambda_host_lifecycle:quiesce(500)}
        end),
        await_admission(quiescing, 100),
        {ok, NewAdmission} = lambda_host_lifecycle:request_admission(),
        ?assertEqual(accepting, maps:get(admission, lambda_host_lifecycle:status())),
        ok = lambda_host_lifecycle:release_admission(Admission),
        ok = lambda_host_lifecycle:release_admission(NewAdmission),
        receive
            {quiesce_result, Owner, {error, invalid_quiesce_handle}} -> ok
        after 1000 ->
            error(quiesce_did_not_observe_returned_demand)
        end
    end).

owner_death_reopens_sealed_runtime_test() ->
    with_lifecycle(fun() ->
        Parent = self(),
        Owner = spawn(fun() ->
            {ok, Handle} = lambda_host_lifecycle:quiesce(100),
            Parent ! {sealed, self(), Handle},
            receive hold -> ok end
        end),
        receive
            {sealed, Owner, _Handle} -> ok
        after 1000 ->
            error(owner_quiesce_timeout)
        end,
        ?assertEqual(sealed, maps:get(admission, lambda_host_lifecycle:status())),
        exit(Owner, kill),
        await_admission(accepting, 100)
    end).

peer_credentials_are_exact_and_fail_closed_test() ->
    Credentials = #{pid => 4242, uid => 1001, gid => 1002},
    Trusted = #{uid => 1001, gid => 1002},
    Binary = <<4242:32/native-signed, 1001:32/native-unsigned, 1002:32/native-unsigned>>,
    ?assertEqual({ok, Credentials},
                 lambda_host_lifecycle_socket:decode_peercred_for_test(Binary)),
    ?assertEqual(ok,
                 lambda_host_lifecycle_socket:authorize_peercred_for_test(
                   {ok, Credentials}, Trusted)),
    ?assertEqual({error, unauthorized_peer},
                 lambda_host_lifecycle_socket:authorize_peercred_for_test(
                   {ok, Credentials}, Trusted#{uid := 1003})),
    ?assertEqual({error, unauthorized_peer},
                 lambda_host_lifecycle_socket:authorize_peercred_for_test(
                   {ok, Credentials}, Trusted#{gid := 1004})),
    ?assertEqual({error, invalid_peercred},
                 lambda_host_lifecycle_socket:decode_peercred_for_test(<<1, 2, 3>>)).

protocol_and_socket_path_are_bounded_test() ->
    ?assertEqual(status,
                 lambda_host_lifecycle_socket:parse_request_for_test(<<"v1 status\n">>)),
    ?assertEqual({quiesce, 300000},
                 lambda_host_lifecycle_socket:parse_request_for_test(
                   <<"v1 quiesce 300000">>)),
    ?assertEqual(invalid,
                 lambda_host_lifecycle_socket:parse_request_for_test(
                   <<"v1 quiesce 300001">>)),
    ?assertEqual(invalid,
                 lambda_host_lifecycle_socket:parse_request_for_test(<<"v2 status">>)),
    ?assertEqual({enabled, "/run/scintilla-lifecycle/control.sock"},
                 lambda_host_lifecycle_socket:validate_socket_path_for_test(
                   "/run/scintilla-lifecycle/control.sock")),
    ?assertEqual({error, invalid_lifecycle_socket_path},
                 lambda_host_lifecycle_socket:validate_socket_path_for_test(
                   "/tmp/scintilla.sock")).

with_lifecycle(Test) ->
    cleanup(),
    {ok, Lifecycle} = lambda_host_lifecycle:start_link(),
    unlink(Lifecycle),
    try
        Test()
    after
        cleanup()
    end.

await_admission(_Expected, 0) ->
    error(admission_state_timeout);
await_admission(Expected, Attempts) ->
    case maps:get(admission, lambda_host_lifecycle:status()) of
        Expected -> ok;
        _Other ->
            timer:sleep(5),
            await_admission(Expected, Attempts - 1)
    end.

cleanup() ->
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
