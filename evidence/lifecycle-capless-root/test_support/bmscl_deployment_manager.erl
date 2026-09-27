-module(bmscl_deployment_manager).

-export([status/0]).

status() ->
    #{admission => accepting, drain_blockers => 0}.
