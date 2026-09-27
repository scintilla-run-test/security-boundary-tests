-module(bmscl_runtime).

-export([quiesce/1, resume/1]).

quiesce(_TimeoutMs) ->
    {error, unsupported_in_socket_carrier}.

resume(_Handle) ->
    {error, unsupported_in_socket_carrier}.
