%% Lifecycle admission wrapper for durable actor operations that execute user code.
-module(lambda_actor_lifecycle).

-export([
    invoke/6,
    invoke_alarm/6,
    reset/2
]).

invoke(Command, FunctionRef, ActorKey, Payload, ChildIdleMs, TimeoutMs) ->
    with_admission(fun() ->
        lambda_actor_manager:invoke(
            Command,
            FunctionRef,
            ActorKey,
            Payload,
            ChildIdleMs,
            TimeoutMs
        )
    end).

invoke_alarm(Command, FunctionRef, ActorKey, ScheduledAt, ChildIdleMs, TimeoutMs) ->
    with_admission(fun() ->
        lambda_actor_manager:invoke_alarm(
            Command,
            FunctionRef,
            ActorKey,
            ScheduledAt,
            ChildIdleMs,
            TimeoutMs
        )
    end).

reset(FunctionRef, ActorKey) ->
    with_admission(fun() ->
        lambda_actor_manager:reset(FunctionRef, ActorKey)
    end).

with_admission(Fun) ->
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
