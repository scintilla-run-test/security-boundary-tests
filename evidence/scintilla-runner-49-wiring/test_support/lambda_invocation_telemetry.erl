-module(lambda_invocation_telemetry).

-export([
    invoke/5,
    invoke_qualified/7,
    invoke_definition/6,
    invoke_stream/6,
    invoke_stream_qualified/8,
    metrics/0
]).

invoke(_Command, _Identifier, _Payload, _IdleMs, _TimeoutMs) ->
    block(invoke).

invoke_qualified(_Command, _Identifier, _Qualifier, _Affinity, _Payload, _IdleMs, _TimeoutMs) ->
    block(invoke_qualified).

invoke_definition(_Command, _Identifier, _Definition, _Payload, _IdleMs, _TimeoutMs) ->
    block(invoke_definition).

invoke_stream(_Command, _Identifier, _Payload, _IdleMs, _TimeoutMs, _Emit) ->
    block(invoke_stream).

invoke_stream_qualified(
  _Command,
  _Identifier,
  _Qualifier,
  _Affinity,
  _Payload,
  _IdleMs,
  _TimeoutMs,
  _Emit
) ->
    block(invoke_stream_qualified).

metrics() ->
    <<>>.

block(Kind) ->
    case whereis(wiring_probe) of
        undefined ->
            {ok, Kind};
        Probe ->
            Probe ! {telemetry_entered, self(), Kind},
            receive
                continue -> {ok, Kind}
            after 2000 ->
                {error, telemetry_probe_timeout}
            end
    end.
