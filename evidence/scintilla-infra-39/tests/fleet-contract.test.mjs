import assert from "node:assert/strict";
import fs from "node:fs";
import test from "node:test";

const runtime = fs.readFileSync("fleet/nixos/scintilla-runtime.nix", "utf8");
const lifecycle = fs.readFileSync("fleet/nixos/scintilla-lifecycle-agent.nix", "utf8");
const hive = fs.readFileSync("fleet/colmena-hive.nix", "utf8");
const aws = fs.readFileSync("infra/fleet/aws/main.tf", "utf8");
const gcp = fs.readFileSync("infra/fleet/gcp/main.tf", "utf8");

test("bare-process runtime keeps security boundaries explicit", () => {
  for (const required of [
    'SCINTILLA_EXECUTOR = "process"',
    "SCINTILLA_ISOLATION_BINARY",
    "NoNewPrivileges = true",
    'ProtectSystem = "strict"',
    'ProtectProc = "invisible"',
    "PrivateDevices = true",
    "ProtectControlGroups = true",
    "MemoryMax = cfg.memoryMax",
    "CPUQuota = cfg.cpuQuota",
    "TasksMax = cfg.tasksMax",
    "LoadCredential",
  ]) {
    assert.ok(runtime.includes(required), "missing " + required);
  }
  assert.ok(!/Docker|containerd|firecracker/i.test(runtime));
});

test("runtime host paths are evaluated Nix values, never literal interpolation text", () => {
  assert.ok(!runtime.includes("\\${"), "escaped Nix interpolation would emit literal runtime paths");
  for (const required of [
    'users.users.${cfg.runtimeUser}',
    '"d ${cfg.stateRoot} 0750 ${cfg.runtimeUser} scintilla -"',
    'SCINTILLA_ISOLATION_BINARY = "${cfg.isolationPackage}/bin/${cfg.isolationBinary}"',
    'ExecStart = "${cfg.runnerPackage}/bin/${cfg.runnerBinary}"',
    'LoadCredential = lib.mapAttrsToList (name: path: "${name}:${path}") cfg.credentialFiles',
  ]) {
    assert.ok(runtime.includes(required), "missing evaluated interpolation: " + required);
  }
});

test("runtime no longer owns distributed lifecycle or checkpoint authority", () => {
  for (const forbidden of [
    "services.scintillaRuntime.lifecycle",
    "SCINTILLA_LIFECYCLE_PROVIDER",
    "SCINTILLA_LIFECYCLE_ENDPOINT",
    "SCINTILLA_LIFECYCLE_KEY_PREFIX",
    "SCINTILLA_LIFECYCLE_CREDENTIAL_NAME",
    "SCINTILLA_LIFECYCLE_CHECKPOINT_ROOT",
    "SCINTILLA_LIFECYCLE_LEASE_TTL_MS",
    "SCINTILLA_LIFECYCLE_HIBERNATE_AFTER_MS",
    "lifecycleCheckpointRoot",
    "leaseEndpoint",
    "leaseTtlMs",
  ]) {
    assert.ok(!runtime.includes(forbidden), "runtime retained lifecycle authority: " + forbidden);
  }
});

test("external lifecycle agent is separate, root-authenticated, and observe-only", () => {
  for (const required of [
    'controlGroup = "scintilla-lifecycle-control"',
    'managedCgroupRoot = "/sys/fs/cgroup/scintilla-workloads.slice"',
    'productSocket = "/run/scintilla-lifecycle/control.sock"',
    '"d ${socketDirectory} 2770 ${runtimeCfg.runtimeUser} ${controlGroup} -"',
    'SupplementaryGroups = [ controlGroup ]',
    'SCINTILLA_LIFECYCLE_SOCKET = productSocket',
    'SCINTILLA_LIFECYCLE_AGENT_UID = "0"',
    'SCINTILLA_LIFECYCLE_AGENT_GID = "0"',
    'ORES_PROCESS_LIFECYCLE_PRODUCT = "scintilla-run"',
    "ORES_PROCESS_LIFECYCLE_CHECKPOINT_ROOT = compatibilityCheckpointRoot",
    "ORES_PROCESS_LIFECYCLE_PRODUCT_SOCKET = productSocket",
    'ORES_PROCESS_LIFECYCLE_LEASE_BACKEND = "cloudflare-do"',
    'ORES_PROCESS_LIFECYCLE_HIBERNATE_ENABLED = "false"',
    'ORES_PROCESS_LIFECYCLE_EFFECTS_ENABLED = "false"',
    'ExecStartPre = "${cfg.package}/bin/${cfg.binary} preflight"',
    'User = "root"',
    'Group = "root"',
    "CapabilityBoundingSet = [ ]",
    "AmbientCapabilities = [ ]",
    "ProtectControlGroups = true",
    'RestrictAddressFamilies = [ "AF_UNIX" ]',
  ]) {
    assert.ok(lifecycle.includes(required), "missing lifecycle boundary: " + required);
  }

  for (const forbidden of [
    "LoadCredential",
    "ORES_LOCKS_API_TOKEN",
    "LEASE_ENDPOINT",
    "LEASE_PROVIDER",
    "CRIU",
    "criu",
    "CAP_DAC_OVERRIDE",
    "CAP_SYS_ADMIN",
    "ProtectControlGroups = false",
    "ORES_PROCESS_LIFECYCLE_EFFECTS = \"freeze_thaw\"",
  ]) {
    assert.ok(!lifecycle.includes(forbidden), "observe-only agent gained premature authority: " + forbidden);
  }
});

test("colmena can opt into the separately pinned lifecycle agent", () => {
  for (const required of [
    "lifecycleAgentPackage ? null",
    "./nixos/scintilla-lifecycle-agent.nix",
    "services.scintillaLifecycleAgent",
    "package = lifecycleAgentPackage",
    "SCINTILLA_REGION",
    "SCINTILLA_CLOUD",
    "credentialFiles",
  ]) {
    assert.ok(hive.includes(required), "missing hive lifecycle wiring: " + required);
  }
});

test("cloud modules default to private hardened runtime nodes", () => {
  assert.ok(aws.includes("map_public_ip_on_launch = false"));
  assert.ok(aws.includes('http_tokens                 = "required"'));
  assert.ok(aws.includes("encrypted = true"));
  assert.ok(gcp.includes("enable_secure_boot          = true"));
  assert.ok(gcp.includes("enable_vtpm                 = true"));
  assert.ok(gcp.includes("block-project-ssh-keys"));
});

test("fleet variables contain no secret-shaped inputs", () => {
  const all = [
    fs.readFileSync("infra/fleet/aws/variables.tf", "utf8"),
    fs.readFileSync("infra/fleet/gcp/variables.tf", "utf8"),
  ].join("\n");
  assert.ok(!/variable\s+"[^"]*(secret|token|password|credential|private_key)[^"]*"/i.test(all));
});
