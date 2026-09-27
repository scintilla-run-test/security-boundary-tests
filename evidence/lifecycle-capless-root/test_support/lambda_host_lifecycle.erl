-module(lambda_host_lifecycle).

-export([status/0, quiesce/1, quiesce_status/1, resume/1]).

status() ->
    #{admission => accepting, in_flight => 0, queue_depth => 0, idle_for_ms => 1}.

quiesce(_TimeoutMs) ->
    {error, unsupported_in_socket_carrier}.

quiesce_status(_Handle) ->
    {error, unsupported_in_socket_carrier}.

resume(_Handle) ->
    {error, unsupported_in_socket_carrier}.
