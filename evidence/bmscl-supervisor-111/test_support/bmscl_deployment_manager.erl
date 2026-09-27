%% Minimal lifecycle-contract manager used only by the exact-source carrier.
%% It intentionally enforces owner-scoped drain tokens and owner-death recovery.
-module(bmscl_deployment_manager).
-behaviour(gen_server).

-export([start_link/0, status/0]).
-export([init/1, handle_call/3, handle_cast/2, handle_info/2, terminate/2, code_change/3]).

-record(state, {
    drain = undefined
}).

start_link() ->
    gen_server:start_link({local, ?MODULE}, ?MODULE, [], []).

status() ->
    gen_server:call(?MODULE, status).

init([]) ->
    {ok, #state{}}.

handle_call({begin_drain, Token}, {Owner, _Tag}, State = #state{drain = undefined})
  when is_reference(Token) ->
    Monitor = erlang:monitor(process, Owner),
    {reply, ok, State#state{drain = {Token, Owner, Monitor, draining}}};
handle_call({begin_drain, _Token}, _From, State) ->
    {reply, {error, runtime_draining}, State};
handle_call({seal_drain, Token}, {Owner, _Tag},
            State = #state{drain = {Token, Owner, Monitor, draining}}) ->
    {reply, ok, State#state{drain = {Token, Owner, Monitor, sealed}}};
handle_call({seal_drain, _Token}, _From, State) ->
    {reply, {error, invalid_drain}, State};
handle_call({drain_status, Token}, {Owner, _Tag},
            State = #state{drain = {Token, Owner, _Monitor, Phase}}) ->
    {reply, {ok, #{admission => Phase, drain_blockers => 0}}, State};
handle_call({drain_status, _Token}, _From, State) ->
    {reply, {error, invalid_drain}, State};
handle_call({cancel_drain, Token}, {Owner, _Tag},
            State = #state{drain = {Token, Owner, Monitor, _Phase}}) ->
    erlang:demonitor(Monitor, [flush]),
    {reply, ok, State#state{drain = undefined}};
handle_call({cancel_drain, _Token}, _From, State) ->
    {reply, {error, invalid_drain}, State};
handle_call(status, _From, State = #state{drain = undefined}) ->
    {reply, #{admission => accepting, drain_blockers => 0}, State};
handle_call(status, _From, State = #state{drain = {_Token, _Owner, _Monitor, Phase}}) ->
    {reply, #{admission => Phase, drain_blockers => 0}, State};
handle_call(_Request, _From, State) ->
    {reply, {error, unsupported_call}, State}.

handle_cast(_Message, State) ->
    {noreply, State}.

handle_info({'DOWN', Monitor, process, Owner, _Reason},
            State = #state{drain = {_Token, Owner, Monitor, _Phase}}) ->
    {noreply, State#state{drain = undefined}};
handle_info(_Message, State) ->
    {noreply, State}.

terminate(_Reason, _State) ->
    ok.

code_change(_OldVersion, State, _Extra) ->
    {ok, State}.
