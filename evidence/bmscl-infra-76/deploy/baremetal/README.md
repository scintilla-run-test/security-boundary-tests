# BeamScale bare-process fleet

This backend runs BeamScale on a small NixOS fleet without Kubernetes, containers, or mandatory microVMs.

## Responsibilities

- Cloud IaC owns machines, networking, disks, IAM/service identities, DNS and load balancers.
- NixOS owns the complete host configuration.
- Colmena owns stateless multi-host rollout/activation.
- `ores-proc-isolation-cli` owns the mandatory OS process sandbox for tenant-influenced workloads.
- `bmscl-supervisor` owns trusted BEAM supervision, generation selection, hot rollout/drain and capability mediation.
- `bmscl-lifecycle-agent` is the separate host lifecycle process. The currently shipped shared executable is **observe/preflight-only**; effects remain disabled until its trusted lease, demand/dispatch, workload identity and crash-recovery adapters are implemented and proven.

The intended production fleet is 3-9 hosts distributed across at least two regions/failure domains. Region-local quorum/state services must not depend on WAN-synchronous consensus unless explicitly designed for it.

## Idle process lifecycle

See `process-lifecycle.md` for the target runtime-state, fencing, placement-epoch, wake-on-demand, and shard-reassignment contract.

`nixos/bmscl-lifecycle-agent.nix` defines a separate root host service and a dedicated `beamscale-workloads.slice`. The module is intentionally standalone until the fleet's Colmena wrapper imports an exact shared lifecycle-agent package. It is wired to the configuration contract the shared `ores-process-lifecycle-agent` actually ships today: fixed BeamScale product socket, state/checkpoint/cgroup roots, Cloudflare-DO backend identifier, hibernation false and effects false.

The compatibility checkpoint directory exists only because the current v1 shared-agent preflight requires a real directory. The service sees it read-only and receives no CRIU, ptrace, mount, DAC-bypass or cgroup-write authority. It has no lease credential and no IP network address family while effects remain disabled.

The paired `bmscl-supervisor` lifecycle socket is fixed at `/run/beamscale-lifecycle/control.sock`. The private setgid `beamscale-lifecycle-control` directory/group is filesystem reachability only: the host daemon remains primary `uid=0,gid=0`, uses the control group only as a supplementary group, and the supervisor authenticates the kernel `SO_PEERCRED` value before parsing requests. A sibling/runtime process that can reach the socket inode still is not authorized to quiesce or resume the runtime.

The host deployment must provide the exact non-tenant OS user that runs `bmscl-supervisor` as `controlSocketOwner`; this module does not guess a service account. That owner can create the socket inside the private setgid directory and the root lifecycle daemon can reach it without `CAP_DAC_OVERRIDE`.

The first future mutation tranche is cgroup-v2 freeze/thaw for warm-idle runtimes. Freeze/thaw reclaims scheduling CPU but does not claim to release resident memory. Real RAM release requires either deterministic terminate/reconstruct from immutable artifacts plus external durable state, or a separately reviewed typed hibernate/checkpoint helper for an explicitly compatible runtime class. Do not hide CRIU/restore authority behind a generic boolean on the main lifecycle daemon.

The distributed lifecycle design still uses `ORESoftware/ores-locks-and-leases`, with Cloudflare Durable Objects as the initial authority and Fiducia as a later backend swap. BeamScale-native locks must never be required to boot, wake or repair BeamScale itself. The product Unix socket remains cooperative admission/quiesce evidence only; trusted queue/demand and post-wake admission must come from host/control-plane authority before effects may be enabled.

## Isolation policy

`.ores-proc-isolation.yaml` is checked in beside this document. Validate it with the matching pinned `ores-proc-isolation-cli` before deployment. Production automation must record the policy file digest and isolation-tool version/commit used for admission.

The current policy uses only capabilities supported by the isolation CLI v1 schema. Independent host-level cgroup/systemd/NixOS controls should add memory/PID/CPU ceilings; do not invent unsupported YAML fields and assume they are enforced.

Tenant-worker launches must enable the isolation CLI's reviewed BeamScale tripwire mode. The policy exposes only the exact inert-wrapper directory and Unix socket, and replaces tenant `PATH` with the wrapper directory:

```bash
ores-proc-isolation doctor \
  --beamscale-honeypot \
  --config deploy/baremetal/.ores-proc-isolation.yaml

ores-proc-isolation run bmscl-worker \
  --beamscale-honeypot \
  --config deploy/baremetal/.ores-proc-isolation.yaml
```

Do not broaden these mounts to `/opt`, `/run`, `/bin`, `/sbin`, `/usr/bin`, or `/usr/sbin`. The isolation CLI independently rejects those broad paths in BeamScale honeypot mode.

A customer worker must never be launched if:

- the isolation policy cannot be parsed or validated;
- the requested process/profile is missing or ambiguous;
- the expected policy/tool digest differs from the installed copy;
- the host cannot enforce the required sandbox backend;
- `--beamscale-honeypot` is absent for a tenant-worker launch or the exact tripwire directory/socket fails the isolation CLI doctor checks;
- the executable/artifact digest is not admitted;
- a requested capability is broader than the release policy.

## Density rule

Prefer one trusted BEAM runtime to multiplex many lightweight admitted actors/processes where policy permits. Do not create one operating-system process per request merely for symmetry with other lambda platforms; the BeamScale advantage is amortizing the BEAM runtime while preserving per-invocation actor supervision and metering.

OS process boundaries are used where they materially improve tenant/runtime containment. Erlang actor isolation provides additional fault/resource structure inside that boundary, not a substitute for it.
