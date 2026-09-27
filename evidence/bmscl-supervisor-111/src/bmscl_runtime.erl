-module(bmscl_runtime).

%% Trusted control-plane calls, executed OUTSIDE the subtree being replaced.
%% Code installation belongs to the release pipeline, never the bootstrap.
%%
%% `quiesce/1` is the host-lifecycle seam. Unlike `stop/1`, it leaves the
%% runtime subtree alive after admissions are sealed and blocking work drains.
%% The calling process owns the returned handle and MUST remain alive until it
%% calls `resume/1`. If the owner dies, the deployment manager reopens
%% admissions fail-safe.
-export([stop/1, start/0, restart/1, quiesce/1, resume/1, quiesce_status/1]).

stop(DrainTimeout) when is_integer(DrainTimeout), DrainTimeout >= 0 ->
    Manager = whereis(bmscl_deployment_manager),
    Runtime = whereis(bmscl_runtime_sup),
    Bootstrap = whereis(bmscl_sup),
    case is_pid(Manager) andalso is_pid(Runtime) andalso is_pid(Bootstrap) of
        false -> {error, runtime_unavailable};
        true -> drain_and_stop(Bootstrap, Runtime, Manager, DrainTimeout)
    end;
stop(_) ->
    {error, invalid_drain_timeout}.

start() ->
    control_call(fun() -> supervisor:restart_child(bmscl_sup, bmscl_runtime_sup) end).

restart(DrainTimeout) ->
    case stop(DrainTimeout) of
        ok -> start();
        Error -> Error
    end.

%% Seal new admissions and wait until all drain-blocking pins/invocations have
%% exited, without terminating the runtime subtree. The opaque handle contains
%% local Erlang identity and is intentionally not a wire format. A trusted,
%% long-lived local host-control process should own it while the OS-level agent
%% freezes/checkpoints this VM.
quiesce(DrainTimeout) when is_integer(DrainTimeout), DrainTimeout >= 0 ->
    Manager = whereis(bmscl_deployment_manager),
    Runtime = whereis(bmscl_runtime_sup),
    case is_pid(Manager) andalso is_pid(Runtime) of
        false -> {error, runtime_unavailable};
        true -> begin_quiesce(Manager, Runtime, DrainTimeout)
    end;
quiesce(_) ->
    {error, invalid_drain_timeout}.

%% Only the process that acquired the quiesce handle can resume admissions.
%% This preserves deployment-manager ownership semantics and prevents a stale
%% or unrelated local process from reopening a runtime it does not own.
resume(#{manager := Manager, runtime := Runtime, token := Token})
  when is_pid(Manager), is_pid(Runtime), is_reference(Token) ->
    case whereis(bmscl_deployment_manager) =:= Manager andalso
         whereis(bmscl_runtime_sup) =:= Runtime of
        false -> {error, runtime_changed};
        true -> control_call(fun() -> gen_server:call(Manager, {cancel_drain, Token}) end)
    end;
resume(_) ->
    {error, invalid_quiesce_handle}.

quiesce_status(#{manager := Manager, runtime := Runtime, token := Token})
  when is_pid(Manager), is_pid(Runtime), is_reference(Token) ->
    case whereis(bmscl_deployment_manager) =:= Manager andalso
         whereis(bmscl_runtime_sup) =:= Runtime of
        false -> {error, runtime_changed};
        true ->
            case control_call(fun() -> gen_server:call(Manager, {drain_status, Token}) end) of
                {ok, #{admission := sealed} = Status} -> {ok, Status};
                {ok, #{admission := Admission}} -> {error, {not_quiesced, Admission}};
                Error -> Error
            end
    end;
quiesce_status(_) ->
    {error, invalid_quiesce_handle}.

begin_quiesce(Manager, Runtime, Timeout) ->
    Token = make_ref(),
    try
        case gen_server:call(Manager, {begin_drain, Token}) of
            ok ->
                Deadline = erlang:monotonic_time(millisecond) + Timeout,
                case wait_for_drain(Manager, Token, Deadline) of
                    ok ->
                        case whereis(bmscl_runtime_sup) =:= Runtime andalso
                             whereis(bmscl_deployment_manager) =:= Manager of
                            true ->
                                {ok, #{manager => Manager,
                                       runtime => Runtime,
                                       token => Token}};
                            false ->
                                _ = catch gen_server:call(Manager, {cancel_drain, Token}),
                                {error, runtime_changed}
                        end;
                    Error ->
                        _ = catch gen_server:call(Manager, {cancel_drain, Token}),
                        Error
                end;
            Error -> Error
        end
    catch
        exit:Reason ->
            _ = catch gen_server:call(Manager, {cancel_drain, Token}),
            {error, {runtime_control_failed, Reason}}
    end.

drain_and_stop(Bootstrap, Runtime, Manager, Timeout) ->
    Token = make_ref(),
    try
        case gen_server:call(Manager, {begin_drain, Token}) of
            ok ->
                Deadline = erlang:monotonic_time(millisecond) + Timeout,
                case wait_for_drain(Manager, Token, Deadline) of
                    ok ->
                        case whereis(bmscl_runtime_sup) =:= Runtime andalso
                             whereis(bmscl_deployment_manager) =:= Manager of
                            true ->
                                supervisor:terminate_child(Bootstrap, bmscl_runtime_sup);
                            false -> {error, runtime_changed}
                        end;
                    Error -> Error
                end;
            Error -> Error
        end
    catch
        exit:Reason -> {error, {runtime_control_failed, Reason}}
    after
        %% Ordered after any timed-out call to this PID; an old cancellation
        %% cannot affect a freshly started manager. No-op after successful stop.
        _ = catch gen_server:call(Manager, {cancel_drain, Token})
    end.

wait_for_drain(Manager, Token, Deadline) ->
    case gen_server:call(Manager, {seal_drain, Token}) of
        ok -> ok;
        {error, invocations_running} ->
            Remaining = Deadline - erlang:monotonic_time(millisecond),
            case Remaining > 0 of
                true ->
                    receive after erlang:min(Remaining, 10) -> ok end,
                    wait_for_drain(Manager, Token, Deadline);
                false -> {error, drain_timeout}
            end;
        Error -> Error
    end.

control_call(Fun) ->
    try Fun()
    catch exit:Reason -> {error, {runtime_control_failed, Reason}}
    end.
