-module(lambda_invocation_observer).

-export([
    invoke/5,
    invoke_qualified/7,
    invoke_definition/6,
    invoke_stream/7,
    invoke_stream_qualified/9,
    capture_traceparent/0,
    metrics/0,
    classify_result_for_test/1,
    valid_traceparent_for_test/1
]).

invoke(Command, Identifier, Payload, IdleMs, TimeoutMs) ->
    with_lifecycle_admission(fun() ->
        lambda_invocation_telemetry:invoke(
            Command,
            Identifier,
            Payload,
            IdleMs,
            TimeoutMs
        )
    end).

invoke_qualified(
    Command,
    Identifier,
    Qualifier,
    Affinity,
    Payload,
    IdleMs,
    TimeoutMs
) ->
    with_lifecycle_admission(fun() ->
        lambda_invocation_telemetry:invoke_qualified(
            Command,
            Identifier,
            Qualifier,
            Affinity,
            Payload,
            IdleMs,
            TimeoutMs
        )
    end).

invoke_definition(
    Command,
    Identifier,
    Definition,
    Payload,
    IdleMs,
    TimeoutMs
) ->
    with_lifecycle_admission(fun() ->
        lambda_invocation_telemetry:invoke_definition(
            Command,
            Identifier,
            Definition,
            Payload,
            IdleMs,
            TimeoutMs
        )
    end).

invoke_stream(
    Command,
    Identifier,
    Payload,
    IdleMs,
    TimeoutMs,
    Traceparent,
    Emit
) ->
    with_lifecycle_admission(fun() ->
        with_traceparent(Traceparent, fun() ->
            lambda_invocation_telemetry:invoke_stream(
                Command,
                Identifier,
                Payload,
                IdleMs,
                TimeoutMs,
                Emit
            )
        end)
    end).

invoke_stream_qualified(
    Command,
    Identifier,
    Qualifier,
    Affinity,
    Payload,
    IdleMs,
    TimeoutMs,
    Traceparent,
    Emit
) ->
    with_lifecycle_admission(fun() ->
        with_traceparent(Traceparent, fun() ->
            lambda_invocation_telemetry:invoke_stream_qualified(
                Command,
                Identifier,
                Qualifier,
                Affinity,
                Payload,
                IdleMs,
                TimeoutMs,
                Emit
            )
        end)
    end).

metrics() ->
    lambda_invocation_telemetry:metrics().

capture_traceparent() ->
    try
        SpanCtx = otel_tracer:current_span_ctx(),
        Metadata = otel_span:hex_span_ctx(SpanCtx),
        TraceId = maps:get(otel_trace_id, Metadata, <<>>),
        SpanId = maps:get(otel_span_id, Metadata, <<>>),
        Flags = maps:get(otel_trace_flags, Metadata, <<>>),
        Header = <<
            "00-",
            TraceId/binary,
            "-",
            SpanId/binary,
            "-",
            Flags/binary
        >>,
        case valid_traceparent(Header) of
            true -> Header;
            false -> <<>>
        end
    catch
        _:_ -> <<>>
    end.

classify_result_for_test(Result) ->
    classify_result(Result).

valid_traceparent_for_test(Header) ->
    valid_traceparent(Header).

with_lifecycle_admission(Fun) ->
    case lambda_host_lifecycle:request_admission() of
        {ok, Admission} ->
            try Fun()
            after
                _ = lambda_host_lifecycle:release_admission(Admission)
            end;
        {error, lifecycle_sealed} ->
            {error, <<"runtime lifecycle is sealed for host suspension">>};
        {error, _Reason} ->
            {error, <<"runtime lifecycle admission is unavailable">>}
    end.

with_traceparent(Header, Fun) ->
    Token = attach_traceparent(Header),
    try Fun()
    after detach_context(Token)
    end.

attach_traceparent(Header) ->
    case valid_traceparent(Header) of
        false -> undefined;
        true ->
            try
                Carrier = [{<<"traceparent">>, Header}],
                Context = otel_propagator_trace_context:extract(
                    otel_ctx:get_current(),
                    Carrier,
                    fun(_Carrier) -> [<<"traceparent">>] end,
                    fun carrier_get/2,
                    []
                ),
                otel_ctx:attach(Context)
            catch
                _:_ -> undefined
            end
    end.

carrier_get(Key, Carrier) ->
    case lists:keyfind(Key, 1, Carrier) of
        {Key, Value} -> Value;
        false -> undefined
    end.

detach_context(undefined) -> ok;
detach_context(Token) ->
    try otel_ctx:detach(Token) catch _:_ -> ok end.

valid_traceparent(
    <<"00-", TraceId:32/binary, "-", SpanId:16/binary, "-", Flags:2/binary>>
) ->
    is_lower_hex(TraceId) andalso
        is_lower_hex(SpanId) andalso
        is_lower_hex(Flags) andalso
        TraceId =/= <<"00000000000000000000000000000000">> andalso
        SpanId =/= <<"0000000000000000">>;
valid_traceparent(_Header) ->
    false.

is_lower_hex(Binary) ->
    lists:all(
        fun(Character) ->
            (Character >= $0 andalso Character =< $9) orelse
                (Character >= $a andalso Character =< $f)
        end,
        binary_to_list(Binary)
    ).

classify_result({ok, _Value}) -> success;
classify_result({error, Reason}) -> classify_error(Reason);
classify_result(_Other) -> internal_error.

classify_error(Reason) ->
    Lower = string:lowercase(to_list(Reason)),
    case contains(Lower, "timed out") orelse contains(Lower, "timeout") of
        true -> timeout;
        false ->
            case contains(Lower, "concurrency limit") orelse
                contains(Lower, "too many requests") orelse
                contains(Lower, "throttl") of
                true -> throttle;
                false ->
                    case contains(Lower, "exited") orelse
                        contains(Lower, "worker unavailable") of
                        true -> crash;
                        false -> error
                    end
            end
    end.

contains(Haystack, Needle) ->
    string:find(Haystack, Needle) =/= nomatch.

to_list(Value) when is_binary(Value) -> unicode:characters_to_list(Value);
to_list(Value) when is_list(Value) -> Value;
to_list(Value) -> lists:flatten(io_lib:format("~0p", [Value])).
