import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";

const nix = await readFile("deploy/baremetal/nixos/bmscl-lifecycle-agent.nix", "utf8");
const docs = await readFile("deploy/baremetal/process-lifecycle.md", "utf8");
const readme = await readFile("deploy/baremetal/README.md", "utf8");

for (const required of [
  'controlGroup = "beamscale-lifecycle-control"',
  'stateRoot = "/var/lib/beamscale/lifecycle"',
  'compatibilityCheckpointRoot = "/var/lib/beamscale/lifecycle-disabled-checkpoints"',
  'managedCgroupRoot = "/sys/fs/cgroup/beamscale-workloads.slice"',
  'productSocket = "/run/beamscale-lifecycle/control.sock"',
  'controlSocketOwner = lib.mkOption',
  '"d ${socketDirectory} 2770 ${cfg.controlSocketOwner} ${controlGroup} -"',
  'ORES_PROCESS_LIFECYCLE_PRODUCT = "beamscale"',
  'ORES_PROCESS_LIFECYCLE_CHECKPOINT_ROOT = compatibilityCheckpointRoot',
  'ORES_PROCESS_LIFECYCLE_PRODUCT_SOCKET = productSocket',
  'ORES_PROCESS_LIFECYCLE_LEASE_BACKEND = "cloudflare-do"',
  'ORES_PROCESS_LIFECYCLE_HIBERNATE_ENABLED = "false"',
  'ORES_PROCESS_LIFECYCLE_EFFECTS_ENABLED = "false"',
  'ExecStartPre = "${cfg.package}/bin/${cfg.binary} preflight"',
  'SupplementaryGroups = [ controlGroup ]',
  'CapabilityBoundingSet = [ ]',
  'AmbientCapabilities = [ ]',
  'ProtectControlGroups = true',
  'RestrictAddressFamilies = [ "AF_UNIX" ]',
  'ReadOnlyPaths = [',
  'ReadWritePaths = [ stateRoot ]',
]) {
  assert.ok(nix.includes(required), `missing observe-only lifecycle invariant: ${required}`);
}

for (const forbidden of [
  "leaseProvider = lib.mkOption",
  "leaseEndpoint = lib.mkOption",
  "credentialName = lib.mkOption",
  "credentialFiles = lib.mkOption",
  "LoadCredential",
  "ORES_PROCESS_LIFECYCLE_LEASE_PROVIDER",
  "ORES_PROCESS_LIFECYCLE_LEASE_ENDPOINT",
  "ORES_PROCESS_LIFECYCLE_LEASE_KEY_PREFIX",
  "ORES_PROCESS_LIFECYCLE_CREDENTIAL_NAME",
  'ORES_PROCESS_LIFECYCLE_EFFECTS = "freeze_thaw"',
  "CAP_DAC_OVERRIDE",
  "CAP_SYS_ADMIN",
  "CAP_SYS_PTRACE",
  "ProtectControlGroups = false",
  'RestrictAddressFamilies = [ "AF_UNIX" "AF_INET" "AF_INET6" ]',
  "managedCgroupRoot\n        ];",
]) {
  assert.ok(!nix.includes(forbidden), `premature lifecycle authority: ${forbidden}`);
}

assert.ok(
  /ReadOnlyPaths = \[[\s\S]*"\/sys\/fs\/cgroup"[\s\S]*compatibilityCheckpointRoot[\s\S]*\];/.test(nix),
  "observe-only agent must see cgroups and compatibility checkpoint root read-only",
);
assert.ok(
  /ReadWritePaths = \[ stateRoot \];/.test(nix),
  "observe-only agent may write only its lifecycle record root",
);

for (const required of [
  "ORESoftware/ores-locks-and-leases",
  "beamscale/runtime-lifecycle/<environment>/<region>/<runtime-id>",
  "fresh logical request",
  "fencing token is newer",
  "separately reviewed checkpoint helper",
]) {
  assert.ok(docs.includes(required), `lifecycle docs missing: ${required}`);
}

for (const required of [
  "observe/preflight-only",
  "SO_PEERCRED",
  "beamscale-lifecycle-control",
  "effects remain disabled",
  "freeze/thaw",
  "Real RAM",
]) {
  assert.ok(readme.includes(required), `baremetal README missing: ${required}`);
}

console.log("BeamScale lifecycle agent contract: bootable observe-only boundary ok");
