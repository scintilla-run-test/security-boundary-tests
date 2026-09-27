-module(lambda_runtime_supervisor).
-behaviour(supervisor).

-export([
    start_link/0,
    ensure_started/0,
    start_worker/1,
    healthy/0,
    draining/0,
    lifecycle_status/0,
    snapshot/0,
    metrics/0
]).
-export([init/1, start_worker_supervisor/0]).

-define(ROOT, lambda_runtime_supervisor).
-define(WORKER_SUPERVISOR, lambda_runtime_worker_supervisor).
-define(MANAGER, lambda_child_runner_manager).
-define(ROUTE_TABLE, lambda_route_table).
-define(HOST_LIFECYCLE, lambda_host_lifecycle).
-define(HOST_LIFECYCLE_SOCKET, lambda_host_lifecycle_socket).

%% The root is the replaceable P2/daddy runtime tree. P1/granddaddy remains
%% outside this module and has no application route knowledge. one_for_all is
%% deliberate: worker/revision state and the published route snapshot form one
%% coherent runtime generation.
start_link() ->
    supervisor:start_link({local, ?ROOT}, ?MODULE, root).

%% Direct FFI tests can reach the child runner without starting the HTTP
%% application. Keep that path supervised too, while production starts this
%% module as a child of the Gleam root supervisor.
ensure_started() ->
    case whereis(?ROOT) of
        Pid when is_pid(Pid) ->
            ok;
        undefined ->
            case start_link() of
                {ok, Pid} ->
                    unlink(Pid),
                    ok;
                {error, {already_started, _Pid}} ->
                    ok;
                {error, Reason} ->
                    {error, Reason}
            end
    end.

start_worker_supervisor() ->
    supervisor:start_link({local, ?WORKER_SUPERVISOR}, ?MODULE, workers).

%% Every warm runtime is a temporary dynamic child. A failed runtime is removed
%% from the manager registry by its monitor and recreated by the next invoke;
%% it never takes down unrelated runtimes or the HTTP server.
start_worker(Command) ->
    ChildSpec = #{
        id => make_ref(),
        start => {lambda_child_runner, start_worker_link, [Command]},
        restart => temporary,
        shutdown => 5000,
        type => worker,
        modules => [lambda_child_runner]
    },
    supervisor:start_child(?WORKER_SUPERVISOR, ChildSpec).

init(root) ->
    Flags = #{
        strategy => one_for_all,
        intensity => 5,
        period => 10
    },
    HostLifecycle = #{
        id => host_lifecycle,
        start => {lambda_host_lifecycle, start_link, []},
        restart => permanent,
        shutdown => 5000,
        type => worker,
        modules => [lambda_host_lifecycle]
    },
    HostLifecycleSocket = #{
        id => host_lifecycle_socket,
        start => {lambda_host_lifecycle_socket, start_link, []},
        restart => permanent,
        shutdown => 5000,
        type => worker,
        modules => [lambda_host_lifecycle_socket]
    },
    RouteTable = #{
        id => route_table,
        start => {lambda_route_table, start_link, []},
        restart => permanent,
        shutdown => 5000,
        type => worker,
        modules => [lambda_route_table]
    },
    WorkerSupervisor = #{
        id => runtime_workers,
        start => {?MODULE, start_worker_supervisor, []},
        restart => permanent,
        shutdown => infinity,
        type => supervisor,
        modules => [?MODULE]
    },
    Manager = #{
        id => runtime_manager,
        start => {lambda_child_runner, start_manager_link, []},
        restart => permanent,
        shutdown => 10000,
        type => worker,
        modules => [lambda_child_runner]
    },
    {ok, {Flags, [
        HostLifecycle,
        HostLifecycleSocket,
        RouteTable,
        WorkerSupervisor,
        Manager
    ]}};
init(workers) ->
    Flags = #{
        strategy => one_for_one,
        intensity => 100,
        period => 10
    },
    {ok, {Flags, []}}.

healthy() ->
    process_alive(whereis(?ROOT)) andalso
        process_alive(whereis(?HOST_LIFECYCLE)) andalso
        process_alive(whereis(?HOST_LIFECYCLE_SOCKET)) andalso
        process_alive(whereis(?ROUTE_TABLE)) andalso
        process_alive(whereis(?WORKER_SUPERVISOR)) andalso
        process_alive(whereis(?MANAGER)).

draining() ->
    marker_draining() orelse lifecycle_draining().

lifecycle_status() ->
    case whereis(?HOST_LIFECYCLE) of
        Pid when is_pid(Pid) ->
            case catch lambda_host_lifecycle:status() of
                Status when is_map(Status) -> Status;
                _ -> #{admission => unavailable, in_flight => 0, queue_depth => 0, idle_for_ms => 0}
            end;
        undefined ->
            #{admission => unavailable, in_flight => 0, queue_depth => 0, idle_for_ms => 0}
    end.

snapshot() ->
    Counts = worker_counts(),
    PoolCounts = lambda_child_runner:worker_counts(),
    Lifecycle = lifecycle_status(),
    Active = maps:get(active, Counts, 0),
    Specs = maps:get(specs, Counts, 0),
    RoutingVersion = routing_version(),
    Backend = lambda_execution_backend:describe(),
    BackendName = maps:get(backend, Backend, <<"invalid">>),
    Provider = maps:get(provider, Backend, <<"local">>),
    ProviderRuntime = maps:get(provider_runtime, Backend, <<>>),
    iolist_to_binary([
        "{\"ok\":", bool_json(healthy()),
        ",\"supervisionStrategy\":\"one_for_all\"",
        ",\"dynamicChildren\":true",
        ",\"draining\":", bool_json(draining()),
        ",\"lifecycleSocketEnabled\":", bool_json(lambda_host_lifecycle_socket:enabled()),
        ",\"admission\":\"", admission_json(maps:get(admission, Lifecycle, unavailable)), "\"",
        ",\"inFlight\":", integer_to_binary(maps:get(in_flight, Lifecycle, 0)),
        ",\"queueDepth\":", integer_to_binary(maps:get(queue_depth, Lifecycle, 0)),
        ",\"idleForMs\":", integer_to_binary(maps:get(idle_for_ms, Lifecycle, 0)),
        ",\"routingVersion\":", integer_to_binary(RoutingVersion),
        ",\"executionBackend\":\"", json_safe_token(BackendName), "\"",
        ",\"provider\":\"", json_safe_token(Provider), "\"",
        ",\"providerRuntime\":\"", json_safe_token(ProviderRuntime), "\"",
        ",\"activeWorkers\":", integer_to_binary(Active),
        ",\"workerSpecs\":", integer_to_binary(Specs),
        ",\"busyWorkers\":", integer_to_binary(maps:get(busy, PoolCounts, 0)),
        ",\"idleWorkers\":", integer_to_binary(maps:get(idle, PoolCounts, 0)),
        "}"
    ]).

metrics() ->
    Counts = worker_counts(),
    Lifecycle = lifecycle_status(),
    iolist_to_binary([
        "# HELP dd_lambda_runner_supervisor_up Whether the BEAM runtime supervision tree is healthy.\n",
        "# TYPE dd_lambda_runner_supervisor_up gauge\n",
        metric_line("dd_lambda_runner_supervisor_up", bool_int(healthy())),
        "# HELP dd_lambda_runner_supervised_workers Active dynamic runtime children supervised by OTP.\n",
        "# TYPE dd_lambda_runner_supervised_workers gauge\n",
        metric_line("dd_lambda_runner_supervised_workers", maps:get(active, Counts, 0)),
        "# HELP dd_lambda_runner_draining Whether this runner has stopped accepting new traffic.\n",
        "# TYPE dd_lambda_runner_draining gauge\n",
        metric_line("dd_lambda_runner_draining", bool_int(draining())),
        "# HELP dd_lambda_runner_lifecycle_in_flight Locally admitted work holding lifecycle tokens.\n",
        "# TYPE dd_lambda_runner_lifecycle_in_flight gauge\n",
        metric_line("dd_lambda_runner_lifecycle_in_flight", maps:get(in_flight, Lifecycle, 0)),
        "# HELP dd_lambda_runner_lifecycle_idle_ms Milliseconds since the lifecycle admission set became empty.\n",
        "# TYPE dd_lambda_runner_lifecycle_idle_ms gauge\n",
        metric_line("dd_lambda_runner_lifecycle_idle_ms", maps:get(idle_for_ms, Lifecycle, 0)),
        "# HELP dd_lambda_runner_lifecycle_socket_enabled Whether the trusted host-control Unix socket is configured.\n",
        "# TYPE dd_lambda_runner_lifecycle_socket_enabled gauge\n",
        metric_line(
            "dd_lambda_runner_lifecycle_socket_enabled",
            bool_int(lambda_host_lifecycle_socket:enabled())
        ),
        "# HELP dd_lambda_runner_routing_version Active immutable HTTP routing snapshot.\n",
        "# TYPE dd_lambda_runner_routing_version gauge\n",
        metric_line("dd_lambda_runner_routing_version", routing_version())
    ]).

marker_draining() ->
    Marker = case os:getenv("SCINTILLA_DRAIN_MARKER") of
        false -> "/tmp/scintilla-draining";
        Value -> Value
    end,
    filelib:is_regular(Marker).

lifecycle_draining() ->
    case lifecycle_status() of
        #{admission := accepting} -> false;
        _ -> true
    end.

routing_version() ->
    case whereis(?ROUTE_TABLE) of
        Pid when is_pid(Pid) ->
            case catch lambda_route_table:snapshot() of
                {ok, Version, _} when is_integer(Version) -> Version;
                _ -> 0
            end;
        undefined -> 0
    end.

worker_counts() ->
    case whereis(?WORKER_SUPERVISOR) of
        Pid when is_pid(Pid) ->
            try maps:from_list(supervisor:count_children(Pid)) of
                Counts -> Counts
            catch
                _:_ -> #{}
            end;
        undefined ->
            #{}
    end.

process_alive(Pid) when is_pid(Pid) ->
    erlang:is_process_alive(Pid);
process_alive(_) ->
    false.

bool_json(true) -> "true";
bool_json(false) -> "false".

bool_int(true) -> 1;
bool_int(false) -> 0.

admission_json(accepting) -> <<"accepting">>;
admission_json(quiescing) -> <<"quiescing">>;
admission_json(sealed) -> <<"sealed">>;
admission_json(_) -> <<"unavailable">>.

json_safe_token(Value) when is_binary(Value) ->
    case re:run(Value, "^[A-Za-z0-9._:-]{0,128}$", [{capture, none}]) of
        match -> Value;
        nomatch -> <<"invalid">>
    end;
json_safe_token(_) ->
    <<"invalid">>.

metric_line(Name, Value) ->
    io_lib:format("~s{service=\"dd-gleam-lambda-runner\"} ~p~n", [Name, Value]).
