use anyhow::{bail, Context, Result};
use axum::{
    extract::{Path as AxumPath, State},
    http::{HeaderMap, StatusCode},
    routing::{get, post, put},
    Json, Router,
};
use rand::{rng, RngCore};
use serde::{Deserialize, Serialize};
use serde_json::{json, Value};
use sha2::{Digest, Sha256};
use std::{
    collections::{BTreeMap, HashMap},
    env,
    fs::{self, OpenOptions},
    io::Write,
    net::SocketAddr,
    path::PathBuf,
    process::{Child, Command, Stdio},
    sync::{Arc, Mutex, MutexGuard},
    thread,
    time::{Duration, Instant, SystemTime, UNIX_EPOCH},
};
use tracing::{info, warn};
use tracing_subscriber::EnvFilter;

const DEFAULT_LISTEN: &str = "127.0.0.1:32123";
const API_VERSION: &str = "scintilla.desktop-daemon/v1";

type ApiError = (StatusCode, Json<Value>);
type ApiResult = std::result::Result<Json<Value>, ApiError>;

#[derive(Clone)]
struct AppState {
    inner: Arc<Mutex<DaemonState>>,
    token: Arc<String>,
    data_root: Arc<PathBuf>,
    manifest_path: Arc<Option<PathBuf>>,
}

struct DaemonState {
    manifest: DesktopManifest,
    ingress: Option<ManagedChild>,
    workers: HashMap<String, ManagedChild>,
    tunnel: Option<ManagedChild>,
    keep_awake: Option<ManagedChild>,
    preferences: Preferences,
}

struct ManagedChild {
    child: Child,
    component: String,
    started_at_unix_ms: u128,
}

#[derive(Clone, Debug, Deserialize, Serialize)]
#[serde(default)]
struct DesktopManifest {
    version: u32,
    runtime_kind: String,
    ingress: Option<ComponentSpec>,
    autostart_ingress: bool,
    workers: Vec<WorkerSpec>,
    tunnel: Option<TunnelSpec>,
    update: Option<UpdateSpec>,
    shutdown_grace_ms: u64,
}

impl Default for DesktopManifest {
    fn default() -> Self {
        return Self {
            version: 1,
            runtime_kind: "scintilla-single-beam".to_owned(),
            ingress: None,
            autostart_ingress: false,
            workers: Vec::new(),
            tunnel: None,
            update: None,
            shutdown_grace_ms: 3_000,
        };
    }
}

#[derive(Clone, Debug, Deserialize, Serialize)]
struct ComponentSpec {
    name: String,
    argv: Vec<String>,
    #[serde(default)]
    working_dir: Option<PathBuf>,
    #[serde(default)]
    env: BTreeMap<String, String>,
    #[serde(default)]
    version: Option<String>,
}

#[derive(Clone, Debug, Deserialize, Serialize)]
struct WorkerSpec {
    name: String,
    mode: WorkerMode,
    #[serde(default)]
    autostart: bool,
    component: ComponentSpec,
}

#[derive(Clone, Debug, Deserialize, Serialize)]
#[serde(rename_all = "snake_case")]
enum WorkerMode {
    Host,
    Container,
}

#[derive(Clone, Debug, Deserialize, Serialize)]
#[serde(default)]
struct TunnelSpec {
    binary: String,
    name: String,
    hostname: Option<String>,
    config: Option<PathBuf>,
    #[serde(default)]
    autostart: bool,
}

impl Default for TunnelSpec {
    fn default() -> Self {
        return Self {
            binary: "cloudflared".to_owned(),
            name: String::new(),
            hostname: None,
            config: None,
            autostart: false,
        };
    }
}

#[derive(Clone, Debug, Deserialize, Serialize)]
struct UpdateSpec {
    artifact_path: PathBuf,
    sha256: String,
    hot_update_argv: Vec<String>,
}

#[derive(Clone, Debug, Default, Deserialize, Serialize)]
struct Preferences {
    keep_scintilla_alive_during_lock_screen: bool,
}

#[derive(Debug, Deserialize)]
struct WorkerStartRequest {
    name: String,
}

#[derive(Debug, Default, Deserialize)]
struct TunnelStartRequest {
    tunnel_name: Option<String>,
    name: Option<String>,
    hostname: Option<String>,
    config: Option<PathBuf>,
}

#[derive(Debug, Deserialize)]
struct PreferencesPatch {
    keep_scintilla_alive_during_lock_screen: bool,
}

#[derive(Debug, Default, Deserialize)]
struct UpdateRequest {
    path: Option<PathBuf>,
    sha256: Option<String>,
}

#[tokio::main]
async fn main() -> Result<()> {
    tracing_subscriber::fmt()
        .with_env_filter(
            EnvFilter::try_from_default_env().unwrap_or_else(|_| EnvFilter::new("info")),
        )
        .init();

    let listen = env::var("SCINTILLA_DAEMON_LISTEN").unwrap_or_else(|_| DEFAULT_LISTEN.to_owned());
    let address: SocketAddr = listen
        .parse()
        .with_context(|| format!("parse SCINTILLA_DAEMON_LISTEN={listen}"))?;
    if !address.ip().is_loopback() {
        bail!("SCINTILLA_DAEMON_LISTEN must be loopback; refusing {address}");
    }

    let data_root = data_root()?;
    fs::create_dir_all(&data_root)
        .with_context(|| format!("create daemon state directory {}", data_root.display()))?;
    let token = load_or_create_token(&data_root)?;
    let manifest_path = env::var_os("SCINTILLA_DESKTOP_MANIFEST").map(PathBuf::from);
    let manifest = load_manifest(manifest_path.as_ref())?;
    validate_manifest(&manifest)?;
    let preferences = load_preferences(&data_root)?;

    let state = AppState {
        inner: Arc::new(Mutex::new(DaemonState {
            manifest,
            ingress: None,
            workers: HashMap::new(),
            tunnel: None,
            keep_awake: None,
            preferences,
        })),
        token: Arc::new(token),
        data_root: Arc::new(data_root),
        manifest_path: Arc::new(manifest_path),
    };

    {
        let mut daemon = state
            .inner
            .lock()
            .map_err(|_| anyhow::anyhow!("daemon state lock poisoned during startup"))?;
        reconcile_autostart(&mut daemon)?;
    }

    let app = Router::new()
        .route("/healthz", get(health))
        .route("/v1/status", get(status))
        .route("/v1/capabilities", get(capabilities))
        .route("/v1/reconcile", post(reconcile))
        .route("/v1/runtime/stop", post(servers_stop))
        .route("/v1/servers/start", post(servers_start))
        .route("/v1/servers/stop", post(servers_stop))
        .route("/v1/servers/restart", post(servers_restart))
        .route("/v1/workers", get(workers_status))
        .route("/v1/workers/start", post(worker_start))
        .route("/v1/workers/{name}/stop", post(worker_stop))
        .route("/v1/tunnel/start", post(tunnel_start))
        .route("/v1/tunnel/stop", post(tunnel_stop))
        .route("/v1/updates/apply", post(update_apply))
        .route("/v1/preferences", put(preferences_update))
        .with_state(state);

    let listener = tokio::net::TcpListener::bind(address)
        .await
        .with_context(|| format!("bind {address}"))?;
    info!(%address, "Scintilla desktop daemon listening");
    axum::serve(listener, app).await.context("serve local daemon")?;
    return Ok(());
}

async fn health() -> Json<Value> {
    return Json(json!({"ok": true, "api": API_VERSION}));
}

async fn status(State(state): State<AppState>, headers: HeaderMap) -> ApiResult {
    authorize(&state, &headers)?;
    let mut daemon = lock_state(&state)?;
    let ingress = child_view(daemon.ingress.as_mut());
    let tunnel = child_view(daemon.tunnel.as_mut());
    let keep_awake = child_view(daemon.keep_awake.as_mut());
    let workers = worker_views(&mut daemon.workers);
    let ingress_version = daemon
        .manifest
        .ingress
        .as_ref()
        .and_then(|component| component.version.clone());

    return Ok(Json(json!({
        "api": API_VERSION,
        "daemon_version": env!("CARGO_PKG_VERSION"),
        "runtime_kind": daemon.manifest.runtime_kind.clone(),
        "manifest_version": daemon.manifest.version,
        "server": {
            "running": ingress["running"].clone(),
            "pid": ingress["pid"].clone(),
            "version": ingress_version,
        },
        "servers": {
            "ingress": {
                "running": ingress["running"].clone(),
                "pid": ingress["pid"].clone(),
                "version": ingress_version,
            }
        },
        "workers": workers,
        "tunnel": tunnel,
        "keep_awake": keep_awake,
        "preferences": daemon.preferences.clone(),
    })));
}

async fn capabilities(State(state): State<AppState>, headers: HeaderMap) -> ApiResult {
    authorize(&state, &headers)?;
    let daemon = lock_state(&state)?;
    return Ok(Json(json!({
        "api": API_VERSION,
        "runtime_kind": daemon.manifest.runtime_kind.clone(),
        "manifest_version": daemon.manifest.version,
        "features": {
            "manifest_reconcile": true,
            "workers": true,
            "cloudflare_tunnel": daemon.manifest.tunnel.is_some(),
            "staged_hot_update": daemon.manifest.update.is_some(),
            "keep_awake": true,
        }
    })));
}

async fn reconcile(State(state): State<AppState>, headers: HeaderMap) -> ApiResult {
    authorize(&state, &headers)?;
    let mut daemon = lock_state(&state)?;
    reload_manifest_if_configured(&state, &mut daemon)?;
    reconcile_autostart(&mut daemon).map_err(internal)?;
    return Ok(Json(json!({"ok": true, "message": "desktop manifest reconciled"})));
}

async fn servers_start(State(state): State<AppState>, headers: HeaderMap) -> ApiResult {
    authorize(&state, &headers)?;
    let mut daemon = lock_state(&state)?;
    reload_manifest_if_configured(&state, &mut daemon)?;

    let already_running = daemon.ingress.as_mut().is_some_and(child_running);
    if already_running {
        return Ok(Json(json!({"ok": true, "message": "ingress already running"})));
    }

    let ingress = daemon
        .manifest
        .ingress
        .clone()
        .ok_or_else(|| conflict("desktop manifest does not define ingress"))?;
    daemon.ingress = Some(spawn_component(&ingress).map_err(|error| internal(error))?);
    refresh_keep_awake(&mut daemon).map_err(|error| internal(error))?;
    return Ok(Json(json!({"ok": true, "message": "ingress started"})));
}

async fn servers_stop(State(state): State<AppState>, headers: HeaderMap) -> ApiResult {
    authorize(&state, &headers)?;
    let mut daemon = lock_state(&state)?;
    let grace_ms = daemon.manifest.shutdown_grace_ms;
    stop_workers(&mut daemon.workers, grace_ms).map_err(|error| internal(error))?;
    stop_managed(&mut daemon.ingress, grace_ms).map_err(|error| internal(error))?;
    stop_managed(&mut daemon.keep_awake, 500).map_err(|error| internal(error))?;
    return Ok(Json(json!({"ok": true, "message": "local servers stopped"})));
}

async fn servers_restart(State(state): State<AppState>, headers: HeaderMap) -> ApiResult {
    authorize(&state, &headers)?;
    let mut daemon = lock_state(&state)?;
    let grace_ms = daemon.manifest.shutdown_grace_ms;
    stop_workers(&mut daemon.workers, grace_ms).map_err(|error| internal(error))?;
    stop_managed(&mut daemon.ingress, grace_ms).map_err(|error| internal(error))?;
    reload_manifest_if_configured(&state, &mut daemon)?;
    let ingress = daemon
        .manifest
        .ingress
        .clone()
        .ok_or_else(|| conflict("desktop manifest does not define ingress"))?;
    daemon.ingress = Some(spawn_component(&ingress).map_err(|error| internal(error))?);
    refresh_keep_awake(&mut daemon).map_err(|error| internal(error))?;
    return Ok(Json(json!({"ok": true, "message": "local ingress restarted"})));
}

async fn workers_status(State(state): State<AppState>, headers: HeaderMap) -> ApiResult {
    authorize(&state, &headers)?;
    let mut daemon = lock_state(&state)?;
    return Ok(Json(json!({"workers": worker_views(&mut daemon.workers)})));
}

async fn worker_start(
    State(state): State<AppState>,
    headers: HeaderMap,
    Json(request): Json<WorkerStartRequest>,
) -> ApiResult {
    authorize(&state, &headers)?;
    let mut daemon = lock_state(&state)?;
    reload_manifest_if_configured(&state, &mut daemon)?;

    let already_running = daemon
        .workers
        .get_mut(&request.name)
        .is_some_and(child_running);
    if already_running {
        return Ok(Json(json!({"ok": true, "message": "worker already running"})));
    }

    let worker = daemon
        .manifest
        .workers
        .iter()
        .find(|worker| worker.name == request.name)
        .cloned()
        .ok_or_else(|| not_found("worker is not declared by desktop manifest"))?;
    let child = spawn_component(&worker.component).map_err(|error| internal(error))?;
    daemon.workers.insert(worker.name.clone(), child);
    return Ok(Json(json!({
        "ok": true,
        "worker": worker.name,
        "mode": worker.mode,
    })));
}

async fn worker_stop(
    State(state): State<AppState>,
    headers: HeaderMap,
    AxumPath(name): AxumPath<String>,
) -> ApiResult {
    authorize(&state, &headers)?;
    let mut daemon = lock_state(&state)?;
    let grace_ms = daemon.manifest.shutdown_grace_ms;
    if let Some(mut child) = daemon.workers.remove(&name) {
        graceful_stop(&mut child.child, grace_ms).map_err(|error| internal(error))?;
    }
    return Ok(Json(json!({"ok": true, "worker": name})));
}

async fn tunnel_start(
    State(state): State<AppState>,
    headers: HeaderMap,
    Json(request): Json<TunnelStartRequest>,
) -> ApiResult {
    authorize(&state, &headers)?;
    let mut daemon = lock_state(&state)?;
    if daemon.tunnel.as_mut().is_some_and(child_running) {
        return Ok(Json(json!({"ok": true, "message": "tunnel already running"})));
    }

    reload_manifest_if_configured(&state, &mut daemon)?;
    validate_tunnel_start_request(&request).map_err(bad_request)?;
    let tunnel = daemon
        .manifest
        .tunnel
        .clone()
        .ok_or_else(|| conflict("desktop manifest does not configure a named tunnel"))?;
    if tunnel.name.trim().is_empty() {
        return Err(conflict("named tunnel is not configured"));
    }

    if let Some(hostname) = tunnel.hostname.as_deref() {
        let status = Command::new(&tunnel.binary)
            .args(["tunnel", "route", "dns", &tunnel.name, hostname])
            .stdin(Stdio::null())
            .status()
            .map_err(|error| internal(error))?;
        if !status.success() {
            return Err(internal(format!(
                "cloudflared route dns failed with {status}"
            )));
        }
    }

    daemon.tunnel = Some(spawn_tunnel(&tunnel).map_err(|error| internal(error))?);
    return Ok(Json(json!({"ok": true, "message": "tunnel started"})));
}

async fn tunnel_stop(State(state): State<AppState>, headers: HeaderMap) -> ApiResult {
    authorize(&state, &headers)?;
    let mut daemon = lock_state(&state)?;
    stop_managed(&mut daemon.tunnel, 2_000).map_err(|error| internal(error))?;
    return Ok(Json(json!({"ok": true, "message": "tunnel stopped"})));
}

async fn preferences_update(
    State(state): State<AppState>,
    headers: HeaderMap,
    Json(patch): Json<PreferencesPatch>,
) -> ApiResult {
    authorize(&state, &headers)?;
    let mut daemon = lock_state(&state)?;
    daemon.preferences.keep_scintilla_alive_during_lock_screen =
        patch.keep_scintilla_alive_during_lock_screen;
    save_preferences(&state.data_root, &daemon.preferences).map_err(|error| internal(error))?;
    refresh_keep_awake(&mut daemon).map_err(|error| internal(error))?;
    return Ok(Json(json!({
        "ok": true,
        "preferences": daemon.preferences.clone(),
    })));
}

async fn update_apply(
    State(state): State<AppState>,
    headers: HeaderMap,
    Json(request): Json<UpdateRequest>,
) -> ApiResult {
    authorize(&state, &headers)?;
    let mut daemon = lock_state(&state)?;
    reload_manifest_if_configured(&state, &mut daemon)?;
    let update = daemon
        .manifest
        .update
        .clone()
        .ok_or_else(|| conflict("desktop manifest does not define a staged update"))?;
    validate_update_request(&request).map_err(bad_request)?;
    let artifact_path = update.artifact_path.clone();
    let expected_sha = update.sha256.clone();
    let actual_sha = sha256_file(&artifact_path).map_err(|error| internal(error))?;
    if !actual_sha.eq_ignore_ascii_case(expected_sha.trim()) {
        return Err(conflict(
            "staged update SHA-256 does not match desktop manifest",
        ));
    }
    if update.hot_update_argv.is_empty() {
        return Err(conflict("desktop manifest update argv is empty"));
    }

    let status = Command::new(&update.hot_update_argv[0])
        .args(&update.hot_update_argv[1..])
        .stdin(Stdio::null())
        .status()
        .map_err(|error| internal(error))?;
    if !status.success() {
        return Err(internal(format!(
            "hot update command failed with {status}"
        )));
    }

    return Ok(Json(json!({
        "ok": true,
        "artifact": artifact_path,
        "sha256": actual_sha,
    })));
}

fn authorize(state: &AppState, headers: &HeaderMap) -> std::result::Result<(), ApiError> {
    let provided = headers
        .get(axum::http::header::AUTHORIZATION)
        .and_then(|value| value.to_str().ok())
        .and_then(|value| value.strip_prefix("Bearer "));
    if !provided.is_some_and(|provided| constant_time_token_eq(provided, state.token.as_str())) {
        return Err((
            StatusCode::UNAUTHORIZED,
            Json(json!({"message": "missing or invalid local daemon bearer token"})),
        ));
    }
    return Ok(());
}

fn validate_tunnel_start_request(request: &TunnelStartRequest) -> std::result::Result<(), &'static str> {
    if request.tunnel_name.is_some()
        || request.name.is_some()
        || request.hostname.is_some()
        || request.config.is_some()
    {
        return Err("tunnel desired state is manifest-owned; client overrides are not allowed");
    }
    return Ok(());
}

fn validate_update_request(request: &UpdateRequest) -> std::result::Result<(), &'static str> {
    if request.path.is_some() || request.sha256.is_some() {
        return Err(
            "staged update path and SHA-256 are manifest-owned; client overrides are not allowed",
        );
    }
    return Ok(());
}

fn constant_time_token_eq(left: &str, right: &str) -> bool {
    let left = Sha256::digest(left.as_bytes());
    let right = Sha256::digest(right.as_bytes());
    let mut difference = 0_u8;
    for index in 0..left.len() {
        difference |= left[index] ^ right[index];
    }
    return difference == 0;
}

fn lock_state(state: &AppState) -> std::result::Result<MutexGuard<'_, DaemonState>, ApiError> {
    return state
        .inner
        .lock()
        .map_err(|_| internal("daemon state lock poisoned"));
}

fn reload_manifest_if_configured(
    state: &AppState,
    daemon: &mut DaemonState,
) -> std::result::Result<(), ApiError> {
    let Some(path) = state.manifest_path.as_ref().as_ref() else {
        return Ok(());
    };
    let manifest = load_manifest(Some(path)).map_err(|error| internal(error))?;
    validate_manifest(&manifest).map_err(|error| internal(error))?;
    daemon.manifest = manifest;
    return Ok(());
}

fn load_manifest(path: Option<&PathBuf>) -> Result<DesktopManifest> {
    let Some(path) = path else {
        return Ok(DesktopManifest::default());
    };
    let bytes = fs::read(path).with_context(|| format!("read manifest {}", path.display()))?;
    return serde_json::from_slice(&bytes)
        .with_context(|| format!("parse desktop manifest {}", path.display()));
}

fn validate_manifest(manifest: &DesktopManifest) -> Result<()> {
    if manifest.version != 1 {
        bail!("unsupported desktop manifest version {}", manifest.version);
    }
    if manifest.runtime_kind != "scintilla-single-beam" {
        bail!(
            "desktop manifest runtime_kind must be scintilla-single-beam, got {}",
            manifest.runtime_kind
        );
    }
    if manifest.autostart_ingress && manifest.ingress.is_none() {
        bail!("autostart_ingress requires a configured ingress");
    }
    if let Some(ingress) = manifest.ingress.as_ref() {
        validate_component(ingress)?;
    }
    for worker in &manifest.workers {
        if worker.name.trim().is_empty() {
            bail!("worker name must not be empty");
        }
        validate_component(&worker.component)?;
    }
    if let Some(update) = manifest.update.as_ref() {
        if update.sha256.len() != 64 {
            bail!("update sha256 must contain 64 hexadecimal characters");
        }
        if update.hot_update_argv.is_empty() {
            bail!("update hot_update_argv must not be empty");
        }
    }
    return Ok(());
}

fn validate_component(component: &ComponentSpec) -> Result<()> {
    if component.name.trim().is_empty() {
        bail!("component name must not be empty");
    }
    if component.argv.is_empty() || component.argv[0].trim().is_empty() {
        bail!("component {} argv must not be empty", component.name);
    }
    return Ok(());
}

fn spawn_component(component: &ComponentSpec) -> Result<ManagedChild> {
    validate_component(component)?;
    let mut command = Command::new(&component.argv[0]);
    command.args(&component.argv[1..]);
    if let Some(working_dir) = component.working_dir.as_ref() {
        command.current_dir(working_dir);
    }
    command.envs(&component.env);
    command.stdin(Stdio::null());
    configure_process_tree(&mut command);
    let child = command
        .spawn()
        .with_context(|| format!("spawn component {}", component.name))?;
    return Ok(ManagedChild {
        child,
        component: component.name.clone(),
        started_at_unix_ms: now_ms(),
    });
}

fn reconcile_autostart(daemon: &mut DaemonState) -> Result<()> {
    let ingress_running = daemon.ingress.as_mut().is_some_and(child_running);
    if daemon.manifest.autostart_ingress && !ingress_running {
        let ingress = daemon
            .manifest
            .ingress
            .clone()
            .context("autostart_ingress requires a configured ingress")?;
        daemon.ingress = Some(spawn_component(&ingress)?);
    }

    let workers = daemon
        .manifest
        .workers
        .iter()
        .filter(|worker| worker.autostart)
        .cloned()
        .collect::<Vec<_>>();
    for worker in workers {
        let running = daemon
            .workers
            .get_mut(&worker.name)
            .is_some_and(child_running);
        if !running {
            let child = spawn_component(&worker.component)?;
            daemon.workers.insert(worker.name, child);
        }
    }

    let tunnel_running = daemon.tunnel.as_mut().is_some_and(child_running);
    if !tunnel_running {
        if let Some(tunnel) = daemon
            .manifest
            .tunnel
            .clone()
            .filter(|tunnel| tunnel.autostart)
        {
            daemon.tunnel = Some(spawn_tunnel(&tunnel)?);
        }
    }

    refresh_keep_awake(daemon)?;
    return Ok(());
}

fn spawn_tunnel(tunnel: &TunnelSpec) -> Result<ManagedChild> {
    if tunnel.name.trim().is_empty() {
        bail!("autostart tunnel name must not be empty");
    }
    let mut command = Command::new(&tunnel.binary);
    command.arg("tunnel");
    if let Some(config_path) = tunnel.config.as_ref() {
        command.arg("--config").arg(config_path);
    }
    command.arg("run").arg(&tunnel.name);
    command.stdin(Stdio::null());
    configure_process_tree(&mut command);
    let child = command
        .spawn()
        .with_context(|| format!("start Cloudflare tunnel {}", tunnel.name))?;
    return Ok(ManagedChild {
        child,
        component: "cloudflared".to_owned(),
        started_at_unix_ms: now_ms(),
    });
}

#[cfg(unix)]
fn configure_process_tree(command: &mut Command) {
    use std::os::unix::process::CommandExt;
    command.process_group(0);
}

#[cfg(not(unix))]
fn configure_process_tree(_command: &mut Command) {}

fn child_running(child: &mut ManagedChild) -> bool {
    return match child.child.try_wait() {
        Ok(None) => true,
        Ok(Some(_)) => false,
        Err(error) => {
            warn!(component = %child.component, %error, "cannot inspect child status");
            false
        }
    };
}

fn child_view(child: Option<&mut ManagedChild>) -> Value {
    let Some(child) = child else {
        return json!({"running": false, "pid": null});
    };
    let running = child_running(child);
    return json!({
        "running": running,
        "pid": if running { Some(child.child.id()) } else { None },
        "component": child.component.clone(),
        "started_at_unix_ms": child.started_at_unix_ms,
    });
}

fn worker_views(workers: &mut HashMap<String, ManagedChild>) -> Value {
    let mut views = serde_json::Map::new();
    for (name, child) in workers.iter_mut() {
        views.insert(name.clone(), child_view(Some(child)));
    }
    return Value::Object(views);
}

fn stop_workers(workers: &mut HashMap<String, ManagedChild>, grace_ms: u64) -> Result<()> {
    for (_, mut worker) in workers.drain() {
        graceful_stop(&mut worker.child, grace_ms)?;
    }
    return Ok(());
}

fn stop_managed(child: &mut Option<ManagedChild>, grace_ms: u64) -> Result<()> {
    if let Some(mut managed) = child.take() {
        graceful_stop(&mut managed.child, grace_ms)?;
    }
    return Ok(());
}

fn graceful_stop(child: &mut Child, grace_ms: u64) -> Result<()> {
    if child.try_wait()?.is_some() {
        return Ok(());
    }

    #[cfg(unix)]
    {
        let group = format!("-{}", child.id());
        let _ = Command::new("kill")
            .args(["-TERM", "--", group.as_str()])
            .stdin(Stdio::null())
            .stdout(Stdio::null())
            .stderr(Stdio::null())
            .status();
    }

    #[cfg(windows)]
    {
        let pid = child.id().to_string();
        let _ = Command::new("taskkill")
            .args(["/PID", pid.as_str(), "/T"])
            .stdin(Stdio::null())
            .stdout(Stdio::null())
            .stderr(Stdio::null())
            .status();
    }

    let deadline = Instant::now() + Duration::from_millis(grace_ms);
    while Instant::now() < deadline {
        if child.try_wait()?.is_some() {
            return Ok(());
        }
        thread::sleep(Duration::from_millis(50));
    }

    #[cfg(unix)]
    {
        let group = format!("-{}", child.id());
        let _ = Command::new("kill")
            .args(["-KILL", "--", group.as_str()])
            .stdin(Stdio::null())
            .stdout(Stdio::null())
            .stderr(Stdio::null())
            .status();
    }

    #[cfg(windows)]
    {
        let pid = child.id().to_string();
        let _ = Command::new("taskkill")
            .args(["/PID", pid.as_str(), "/T", "/F"])
            .stdin(Stdio::null())
            .stdout(Stdio::null())
            .stderr(Stdio::null())
            .status();
    }

    #[cfg(unix)]
    {
        let _ = child.kill();
    }

    #[cfg(not(any(unix, windows)))]
    child.kill().context("force stop child after grace period")?;

    let _ = child.wait();
    return Ok(());
}

fn refresh_keep_awake(daemon: &mut DaemonState) -> Result<()> {
    let ingress_running = daemon.ingress.as_mut().is_some_and(child_running);
    let desired = daemon.preferences.keep_scintilla_alive_during_lock_screen && ingress_running;
    let current = daemon.keep_awake.as_mut().is_some_and(child_running);

    if desired && !current {
        daemon.keep_awake = spawn_keep_awake()?;
    } else if !desired && current {
        stop_managed(&mut daemon.keep_awake, 500)?;
    }
    return Ok(());
}

fn spawn_keep_awake() -> Result<Option<ManagedChild>> {
    #[cfg(target_os = "macos")]
    {
        let pid = std::process::id().to_string();
        let child = Command::new("caffeinate")
            .args(["-i", "-w", pid.as_str()])
            .stdin(Stdio::null())
            .spawn()
            .context("start caffeinate")?;
        return Ok(Some(ManagedChild {
            child,
            component: "keep-awake".to_owned(),
            started_at_unix_ms: now_ms(),
        }));
    }

    #[cfg(target_os = "linux")]
    {
        let child = Command::new("systemd-inhibit")
            .args([
                "--what=sleep",
                "--who=Scintilla",
                "--why=local Scintilla runtime requested keep-awake",
                "--mode=block",
                "sleep",
                "infinity",
            ])
            .stdin(Stdio::null())
            .spawn()
            .context("start systemd-inhibit")?;
        return Ok(Some(ManagedChild {
            child,
            component: "keep-awake".to_owned(),
            started_at_unix_ms: now_ms(),
        }));
    }

    #[cfg(target_os = "windows")]
    {
        let script = r#"Add-Type -TypeDefinition 'using System; using System.Runtime.InteropServices; public class P { [DllImport("kernel32.dll")] public static extern uint SetThreadExecutionState(uint esFlags); }'; while ($true) { [P]::SetThreadExecutionState(0x80000001) | Out-Null; Start-Sleep -Seconds 30 }"#;
        let child = Command::new("powershell")
            .args(["-NoProfile", "-WindowStyle", "Hidden", "-Command", script])
            .stdin(Stdio::null())
            .spawn()
            .context("start Windows keep-awake helper")?;
        return Ok(Some(ManagedChild {
            child,
            component: "keep-awake".to_owned(),
            started_at_unix_ms: now_ms(),
        }));
    }

    #[cfg(not(any(target_os = "macos", target_os = "linux", target_os = "windows")))]
    {
        return Ok(None);
    }
}

fn data_root() -> Result<PathBuf> {
    if let Ok(root) = env::var("SCINTILLA_DESKTOP_HOME") {
        let root = root.trim();
        if !root.is_empty() {
            return Ok(PathBuf::from(root));
        }
    }
    let home = env::var_os("HOME")
        .or_else(|| env::var_os("USERPROFILE"))
        .map(PathBuf::from)
        .context("cannot locate home directory; set SCINTILLA_DESKTOP_HOME")?;
    return Ok(home.join(".scintilla").join("daemon"));
}

fn load_or_create_token(root: &PathBuf) -> Result<String> {
    if let Ok(token) = env::var("SCINTILLA_DAEMON_TOKEN") {
        let token = token.trim().to_owned();
        validate_token(&token).context("SCINTILLA_DAEMON_TOKEN is invalid")?;
        return Ok(token);
    }

    let path = root.join("token");
    if path.exists() {
        let token = fs::read_to_string(&path)
            .with_context(|| format!("read daemon token {}", path.display()))?;
        let token = token.trim().to_owned();
        validate_token(&token)
            .with_context(|| format!("daemon token {} is invalid", path.display()))?;
        return Ok(token);
    }

    let mut bytes = [0_u8; 32];
    rng().fill_bytes(&mut bytes);
    let token = bytes
        .iter()
        .map(|byte| format!("{byte:02x}"))
        .collect::<String>();
    let mut options = OpenOptions::new();
    options.create_new(true).write(true);
    #[cfg(unix)]
    {
        use std::os::unix::fs::OpenOptionsExt;
        options.mode(0o600);
    }
    let mut file = options
        .open(&path)
        .with_context(|| format!("create daemon token {}", path.display()))?;
    writeln!(file, "{token}").context("write daemon token")?;
    return Ok(token);
}

fn validate_token(token: &str) -> Result<()> {
    if token.len() < 32 || token.len() > 4_096 || token.chars().any(char::is_whitespace) {
        bail!("daemon token must contain 32..=4096 non-whitespace characters");
    }
    return Ok(());
}

fn preferences_path(root: &PathBuf) -> PathBuf {
    return root.join("preferences.json");
}

fn load_preferences(root: &PathBuf) -> Result<Preferences> {
    let path = preferences_path(root);
    if !path.exists() {
        return Ok(Preferences::default());
    }
    let bytes = fs::read(&path).with_context(|| format!("read {}", path.display()))?;
    return serde_json::from_slice(&bytes).with_context(|| format!("parse {}", path.display()));
}

fn save_preferences(root: &PathBuf, preferences: &Preferences) -> Result<()> {
    let path = preferences_path(root);
    let bytes = serde_json::to_vec_pretty(preferences)?;
    fs::write(&path, bytes).with_context(|| format!("write {}", path.display()))?;
    return Ok(());
}

fn sha256_file(path: &PathBuf) -> Result<String> {
    let bytes = fs::read(path)
        .with_context(|| format!("read update artifact {}", path.display()))?;
    let digest = Sha256::digest(bytes);
    return Ok(digest
        .iter()
        .map(|byte| format!("{byte:02x}"))
        .collect::<String>());
}

fn now_ms() -> u128 {
    return SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .unwrap_or_default()
        .as_millis();
}

fn internal(error: impl std::fmt::Display) -> ApiError {
    warn!(%error, "desktop daemon request failed");
    return (
        StatusCode::INTERNAL_SERVER_ERROR,
        Json(json!({"message": "local daemon operation failed"})),
    );
}

fn bad_request(message: &str) -> ApiError {
    return (
        StatusCode::BAD_REQUEST,
        Json(json!({"message": message})),
    );
}

fn conflict(message: &str) -> ApiError {
    return (StatusCode::CONFLICT, Json(json!({"message": message})));
}

fn not_found(message: &str) -> ApiError {
    return (StatusCode::NOT_FOUND, Json(json!({"message": message})));
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn bearer_comparison_and_token_policy_fail_closed() {
        assert!(constant_time_token_eq(&"a".repeat(32), &"a".repeat(32)));
        assert!(!constant_time_token_eq(&"a".repeat(32), &"b".repeat(32)));
        assert!(validate_token(&"x".repeat(32)).is_ok());
        assert!(validate_token("short").is_err());
        assert!(validate_token(&format!("{} {}", "x".repeat(32), "y")).is_err());
    }

    #[test]
    fn client_cannot_override_manifest_owned_tunnel_or_update_state() {
        let tunnel = TunnelStartRequest {
            tunnel_name: Some("other".to_owned()),
            ..TunnelStartRequest::default()
        };
        assert!(validate_tunnel_start_request(&tunnel).is_err());
        assert!(validate_tunnel_start_request(&TunnelStartRequest::default()).is_ok());

        let update = UpdateRequest {
            path: Some(PathBuf::from("/tmp/other")),
            sha256: None,
        };
        assert!(validate_update_request(&update).is_err());
        assert!(validate_update_request(&UpdateRequest::default()).is_ok());
    }

    #[test]
    fn rejects_wrong_manifest_kind() {
        let manifest = DesktopManifest {
            runtime_kind: "production-cluster".to_owned(),
            ..DesktopManifest::default()
        };
        assert!(validate_manifest(&manifest).is_err());
    }

    #[test]
    fn accepts_single_beam_manifest() {
        let manifest = DesktopManifest {
            ingress: Some(ComponentSpec {
                name: "ingress".to_owned(),
                argv: vec!["erl".to_owned()],
                working_dir: None,
                env: BTreeMap::new(),
                version: Some("test".to_owned()),
            }),
            ..DesktopManifest::default()
        };
        assert!(validate_manifest(&manifest).is_ok());
    }
}
