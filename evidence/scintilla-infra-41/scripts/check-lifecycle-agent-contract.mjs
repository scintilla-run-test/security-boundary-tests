import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";

const nix = await readFile("fleet/nixos/scintilla-lifecycle-agent.nix", "utf8");

for (const required of [
  'controlGroup = "scintilla-lifecycle-control"',
  'managedCgroupRoot = "/sys/fs/cgroup/scintilla-workloads.slice"',
  'productSocket = "/run/scintilla-lifecycle/control.sock"',
  'SCINTILLA_LIFECYCLE_SOCKET = productSocket',
  'SCINTILLA_LIFECYCLE_AGENT_UID = "0"',
  'SCINTILLA_LIFECYCLE_AGENT_GID = "0"',
  'ORES_PROCESS_LIFECYCLE_PRODUCT = "scintilla-run"',
  'ORES_PROCESS_LIFECYCLE_PRODUCT_SOCKET = productSocket',
  'ORES_PROCESS_LIFECYCLE_LEASE_BACKEND = "cloudflare-do"',
  'ORES_PROCESS_LIFECYCLE_HIBERNATE_ENABLED = "false"',
  'ORES_PROCESS_LIFECYCLE_EFFECTS_ENABLED = "false"',
  '"${cfg.package}/bin/${cfg.binary} preflight"',
  '"${cfg.package}/bin/${cfg.binary} probe-product"',
  'SupplementaryGroups = [ controlGroup ]',
  'CapabilityBoundingSet = [ ]',
  'AmbientCapabilities = [ ]',
  'ProtectControlGroups = true',
  'RestrictAddressFamilies = [ "AF_UNIX" ]',
  'ReadWritePaths = [ stateRoot ]',
]) {
  assert.ok(nix.includes(required), `missing Scintilla lifecycle invariant: ${required}`);
}

assert.match(
  nix,
  /requires = \[[\s\S]*"scintilla-runtime\.service"[\s\S]*"scintilla-workloads\.slice"[\s\S]*\];/,
  "lifecycle observer must require runtime and workload slice",
);
assert.match(
  nix,
  /after = \[[\s\S]*"scintilla-runtime\.service"[\s\S]*"scintilla-workloads\.slice"[\s\S]*\];/,
  "lifecycle observer must start after runtime and workload slice",
);
assert.match(
  nix,
  /ReadOnlyPaths = \[[\s\S]*"\/sys\/fs\/cgroup"[\s\S]*compatibilityCheckpointRoot[\s\S]*\];/,
  "observe-only agent must see cgroups and checkpoint compatibility root read-only",
);

for (const forbidden of [
  'wants = [ "scintilla-runtime.service" ]',
  "LoadCredential",
  "CAP_DAC_OVERRIDE",
  "CAP_SYS_ADMIN",
  "CAP_SYS_PTRACE",
  "ProtectControlGroups = false",
  'RestrictAddressFamilies = [ "AF_UNIX" "AF_INET" "AF_INET6" ]',
  'ORES_PROCESS_LIFECYCLE_EFFECTS_ENABLED = "true"',
  'ORES_PROCESS_LIFECYCLE_HIBERNATE_ENABLED = "true"',
]) {
  assert.ok(!nix.includes(forbidden), `premature Scintilla lifecycle authority: ${forbidden}`);
}

console.log("Scintilla lifecycle observer contract: fail-closed product bridge boundary ok");
