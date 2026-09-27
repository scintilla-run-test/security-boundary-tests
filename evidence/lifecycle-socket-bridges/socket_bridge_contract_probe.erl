-module(socket_bridge_contract_probe).
-export([main/0]).

main() ->
    ok = assert_bridge(
        bmscl_host_lifecycle_socket,
        "/run/beamscale-lifecycle/control.sock"
    ),
    ok = assert_bridge(
        lambda_host_lifecycle_socket,
        "/run/scintilla-lifecycle/control.sock"
    ),
    halt(0).

assert_bridge(Module, ExpectedPath) ->
    {enabled, ExpectedPath} = Module:validate_socket_path_for_test(ExpectedPath),
    {error, invalid_lifecycle_socket_path} =
        Module:validate_socket_path_for_test("/run/attacker-controlled.sock"),
    {error, invalid_lifecycle_socket_path} =
        Module:validate_socket_path_for_test("/tmp/control.sock"),
    status = Module:parse_request_for_test(<<"v1 status">>),
    resume = Module:parse_request_for_test(<<"v1 resume\n">>),
    {quiesce, 30000} = Module:parse_request_for_test(<<"v1 quiesce 30000">>),
    invalid = Module:parse_request_for_test(<<"v1 quiesce 300001">>),
    invalid = Module:parse_request_for_test(<<"v2 status">>),
    ok.
