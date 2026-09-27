%% Trusted local admission/drain boundary for host-level process lifecycle.
%%
%% This module deliberately owns no distributed lock, cgroup, CRIU, scheduler,
%% or checkpoint logic. The external host agent owns those effects. The runner
%% only answers the product-specific question: can new work enter, and has all
%% work admitted by this process drained?
-module(lambda_host_lifecycle).
-behaviour(gen_server).

-export([
    start_link/0,
    request_admission/0,
    release_admission/1,
    quiesce/1,
    resume/1,
    quiesce_status/1,
    status/0,
    ready/0
]).
-export([init/1, handle_call/3, handle_cast/2, handle_info/2, terminate/2]).

-define(SERVER, ?MODULE).

start_link() ->
    gen_server:start_link({local, ?SERVER}, ?MODULE, [], []).

request_admission() ->
    gen_server:call(?SERVER, request_admission, 5000).

release_admission(Token) when is_reference(Token) ->
    gen_server:call(?SERVER, {release_admission, Token}, 5000);
release_admission(_) ->
    {error, invalid_admission_token}.

quiesce(TimeoutMs) when is_integer(TimeoutMs), TimeoutMs >= 0 ->
    case gen_server:call(?SERVER, begin_quiesce, 5000) of
        {ok, Handle} ->
            Deadline = erlang:monotonic_time(millisecond) + TimeoutMs,
            wait_until_sealed(Handle, Deadline);
        Error ->
            Error
    end;
quiesce(_) ->
    {error, invalid_timeout}.

resume(Handle) ->
    gen_server:call(?SERVER, {resume, Handle}, 5000).

quiesce_status(Handle) ->
    gen_server:call(?SERVER, {quiesce_status, Handle}, 5000).

status() ->
    gen_server:call(?SERVER, status, 5000).

ready() ->
    case status() of
        #{admission := accepting} -> true;
        _ -> false
    end.

init([]) ->
    {ok, #{
        admission => accepting,
        admissions => #{},
        admission_monitors => #{},
        quiesce => undefined,
        idle_since_ms => now_ms()
    }}.

handle_call(request_admission, {Owner, _Tag}, State0) ->
    case maps:get(admission, State0) of
        accepting ->
            grant_admission(Owner, State0);
        quiescing ->
            State1 = cancel_quiesce_state(State0),
            grant_admission(Owner, State1);
        sealed ->
            {reply, {error, lifecycle_sealed}, State0}
    end;
handle_call({release_admission, Token}, _From, State0) ->
    {Reply, State1} = release_admission_token(Token, State0),
    {reply, Reply, State1};
handle_call(begin_quiesce, {Owner, _Tag}, State0) ->
    case maps:get(admission, State0) of
        accepting ->
            Token = make_ref(),
            Monitor = erlang:monitor(process, Owner),
            Handle = #{token => Token, owner => Owner},
            Quiesce = #{token => Token, owner => Owner, monitor => Monitor},
            State1 = State0#{admission := quiescing, quiesce := Quiesce},
            {reply, {ok, Handle}, State1};
        quiescing ->
            {reply, {error, already_quiescing}, State0};
        sealed ->
            {reply, {error, already_sealed}, State0}
    end;
handle_call({seal, Handle}, {Owner, _Tag}, State0) ->
    case matching_quiesce(Handle, Owner, State0) of
        false ->
            {reply, {error, invalid_quiesce_handle}, State0};
        true ->
            case map_size(maps:get(admissions, State0)) of
                0 ->
                    State1 = State0#{admission := sealed},
                    {reply, ok, State1};
                Count ->
                    {reply, {error, {in_flight, Count}}, State0}
            end
    end;
handle_call({resume, Handle}, {Owner, _Tag}, State0) ->
    case matching_quiesce(Handle, Owner, State0) of
        false ->
            {reply, {error, invalid_quiesce_handle}, State0};
        true ->
            State1 = cancel_quiesce_state(State0),
            {reply, ok, State1}
    end;
handle_call({quiesce_status, Handle}, {Owner, _Tag}, State) ->
    case matching_quiesce(Handle, Owner, State) of
        false ->
            {reply, {error, invalid_quiesce_handle}, State};
        true ->
            {reply, {ok, public_status(State)}, State}
    end;
handle_call(status, _From, State) ->
    {reply, public_status(State), State};
handle_call(_Request, _From, State) ->
    {reply, {error, unsupported_call}, State}.

handle_cast(_Message, State) ->
    {noreply, State}.

handle_info({'DOWN', Monitor, process, Owner, _Reason}, State0) ->
    case maps:get(quiesce, State0) of
        #{monitor := Monitor, owner := Owner} ->
            {noreply, cancel_quiesce_state(State0)};
        _ ->
            case maps:take(Monitor, maps:get(admission_monitors, State0)) of
                error ->
                    {noreply, State0};
                {Token, Monitors1} ->
                    Admissions1 = maps:remove(Token, maps:get(admissions, State0)),
                    {noreply, update_idle_since(State0#{
                        admissions := Admissions1,
                        admission_monitors := Monitors1
                    })}
            end
    end;
handle_info(_Message, State) ->
    {noreply, State}.

terminate(_Reason, _State) ->
    ok.

wait_until_sealed(Handle, Deadline) ->
    case gen_server:call(?SERVER, {seal, Handle}, 5000) of
        ok ->
            {ok, Handle};
        {error, {in_flight, _Count}} ->
            Remaining = Deadline - erlang:monotonic_time(millisecond),
            case Remaining > 0 of
                true ->
                    receive after erlang:min(Remaining, 10) -> ok end,
                    wait_until_sealed(Handle, Deadline);
                false ->
                    _ = resume(Handle),
                    {error, drain_timeout}
            end;
        Error ->
            Error
    end.

grant_admission(Owner, State0) ->
    Token = make_ref(),
    Monitor = erlang:monitor(process, Owner),
    Admissions1 = maps:put(Token, Owner, maps:get(admissions, State0)),
    Monitors1 = maps:put(Monitor, Token, maps:get(admission_monitors, State0)),
    State1 = State0#{
        admissions := Admissions1,
        admission_monitors := Monitors1,
        idle_since_ms := undefined
    },
    {reply, {ok, Token}, State1}.

release_admission_token(Token, State0) ->
    case maps:take(Token, maps:get(admissions, State0)) of
        error ->
            {{error, unknown_admission_token}, State0};
        {_Owner, Admissions1} ->
            {Monitor, Monitors1} = take_monitor_for_token(
                Token,
                maps:get(admission_monitors, State0)
            ),
            case is_reference(Monitor) of
                true -> erlang:demonitor(Monitor, [flush]);
                false -> ok
            end,
            State1 = update_idle_since(State0#{
                admissions := Admissions1,
                admission_monitors := Monitors1
            }),
            {ok, State1}
    end.

take_monitor_for_token(Token, Monitors) ->
    maps:fold(
        fun(Monitor, Candidate, {Found, Acc}) ->
            case Candidate =:= Token of
                true -> {Monitor, Acc};
                false -> {Found, maps:put(Monitor, Candidate, Acc)}
            end
        end,
        {undefined, #{}},
        Monitors
    ).

matching_quiesce(Handle, Owner, State) when is_map(Handle) ->
    case maps:get(quiesce, State) of
        #{token := Token, owner := Owner} ->
            maps:get(token, Handle, undefined) =:= Token andalso
                maps:get(owner, Handle, undefined) =:= Owner;
        _ ->
            false
    end;
matching_quiesce(_Handle, _Owner, _State) ->
    false.

cancel_quiesce_state(State0) ->
    case maps:get(quiesce, State0) of
        #{monitor := Monitor} ->
            erlang:demonitor(Monitor, [flush]);
        _ ->
            ok
    end,
    State0#{admission := accepting, quiesce := undefined}.

update_idle_since(State0) ->
    case map_size(maps:get(admissions, State0)) of
        0 ->
            case maps:get(idle_since_ms, State0) of
                undefined -> State0#{idle_since_ms := now_ms()};
                _ -> State0
            end;
        _ ->
            State0#{idle_since_ms := undefined}
    end.

public_status(State) ->
    IdleSince = maps:get(idle_since_ms, State),
    IdleFor = case IdleSince of
        undefined -> 0;
        Value -> erlang:max(0, now_ms() - Value)
    end,
    #{
        admission => maps:get(admission, State),
        in_flight => map_size(maps:get(admissions, State)),
        queue_depth => 0,
        idle_for_ms => IdleFor
    }.

now_ms() ->
    erlang:monotonic_time(millisecond).
