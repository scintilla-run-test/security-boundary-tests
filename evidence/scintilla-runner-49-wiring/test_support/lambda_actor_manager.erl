-module(lambda_actor_manager).

-export([
    invoke/6,
    invoke_alarm/6,
    reset/2,
    enabled/0,
    get_state/2,
    snapshot/0,
    metrics/0
]).

invoke(_Command, _FunctionRef, _ActorKey, _Payload, _IdleMs, _TimeoutMs) ->
    block(invoke).

invoke_alarm(_Command, _FunctionRef, _ActorKey, _ScheduledAt, _IdleMs, _TimeoutMs) ->
    block(invoke_alarm).

reset(_FunctionRef, _ActorKey) ->
    block(reset).

enabled() ->
    true.

get_state(_FunctionRef, _ActorKey) ->
    {ok, <<>>}.

snapshot() ->
    <<>>.

metrics() ->
    <<>>.

block(Kind) ->
    case whereis(wiring_probe) of
        undefined ->
            {ok, Kind};
        Probe ->
            Probe ! {actor_entered, self(), Kind},
            receive
                continue -> {ok, Kind}
            after 2000 ->
                {error, actor_probe_timeout}
            end
    end.
