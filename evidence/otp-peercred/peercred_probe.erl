%% Proves a compatibility fact the lifecycle socket threat model depends on:
%% BeamScale's certified OTP 27.3 Linux runtime does not expose SO_PEERCRED through
%% socket:getopt(Connection, {socket, peercred}). Production lifecycle bridges
%% therefore cannot treat Erlang-level peer credentials as their mandatory access
%% control boundary. They must use a private service-manager-owned directory,
%% a fixed socket path, restrictive mode bits, and fail-closed bind semantics.
-module(peercred_probe).
-export([main/0]).

main() ->
    Path = "/tmp/ores-otp-peercred-proof.sock",
    _ = file:delete(Path),
    {ok, Listener} = socket:open(local, stream, default),
    ok = socket:bind(Listener, #{family => local, path => Path}),
    ok = socket:listen(Listener, 4),
    Parent = self(),
    Client = spawn_link(fun() -> client(Path, Parent) end),
    {ok, Connection} = socket:accept(Listener),
    Result = socket:getopt(Connection, {socket, peercred}),
    io:format("OTP_RELEASE=~s~n", [erlang:system_info(otp_release)]),
    io:format("PEERCRED=~p~n", [Result]),
    ok = validate_peercred_result(Result),
    Client ! stop,
    ok = socket:close(Connection),
    ok = socket:close(Listener),
    _ = file:delete(Path),
    halt(0).

client(Path, Parent) ->
    {ok, Socket} = socket:open(local, stream, default),
    ok = socket:connect(Socket, #{family => local, path => Path}),
    Parent ! {client_connected, self()},
    receive
        stop ->
            ok = socket:close(Socket),
            ok
    after 10000 ->
        exit(client_timeout)
    end.

validate_peercred_result({error, {invalid, {socket_option, {socket, peercred}}}}) ->
    ok;
validate_peercred_result(Other) ->
    erlang:error({peercred_contract_changed, Other}).
