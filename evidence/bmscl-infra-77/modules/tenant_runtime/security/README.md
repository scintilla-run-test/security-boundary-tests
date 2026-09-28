# Tenant runtime host security sensors

This directory contains defense-in-depth host sensors for BeamScale tenant runtimes. They supplement compiler admission, `ORESoftware/ores-proc-isolation-cli`, seccomp, cgroup-v2 limits, namespaces, Firecracker/KVM, and normal host hardening. They are not a replacement for those boundaries.

## Decision boundary

The authoritative containment path is owned by `beamscale/bmscl-honeypot-daemon.rs`:

1. a sensor reports a minimal host event;
2. the host re-derives the process cgroup and rejects anything outside `/sys/fs/cgroup/beamscale/**`;
3. the cgroup leaf is mapped to the root-owned runtime identity record;
4. a durable `detected` receipt is fsynced;
5. the exact attributed cgroup is frozen with cgroup v2 and verified frozen;
6. a durable `contained` receipt is fsynced;
7. an unprivileged dispatcher/control-plane path blocks the host-derived BeamScale user/tenant and fans out alerts.

Sensors must never trust a tenant-provided user id, tenant id, deployment id, runtime id, cgroup path, or account email.

## Tetragon proving backend

All policies in `./tetragon` are intentionally **monitor-only**. Tetragon is the proving/reference backend; BeamScale's long-term preferred implementation remains a small in-tree CO-RE eBPF sensor with the same event and containment contract.

### Bare-process Hosted BEAM

`./tetragon/beamscale-bare-process-escape.yaml` records two high-signal classes for bare-process Hosted BEAM runtimes:

- any `execve` originating from the tenant BEAM process, because Hosted Gleam has a no-child-process contract;
- namespace, mount, ptrace, BPF, chroot, and kernel-module syscalls that are incompatible with the tenant runtime contract.

The policy records only the executable path for `execve`. Do not enable process environment capture, full argv retention, tenant file contents, bearer credentials, or general shell history collection.

### Firecracker VMM host escape

`./tetragon/beamscale-firecracker-escape.yaml` watches the **Firecracker VMM process**, not jailer startup, for behavior incompatible with a running microVM:

- an `execve` from Firecracker after launch;
- `setns`, `unshare`, `ptrace`, BPF, or kernel-module syscalls from the running VMM.

Do not apply the same syscall selector to the jailer binary itself. Jailer startup legitimately performs namespace, chroot, cgroup, uid/gid, and other host setup before it execs the VMM. The Firecracker policy is intended to catch guest-to-host exploit execution that is still running in the VMM process context or attempts to pivot from it.

### Decoy resources

`./tetragon/beamscale-decoy-file-access.yaml` watches accesses to synthetic, non-secret canary files such as:

- `/opt/beamscale/.canary/host-identity.json`
- `/opt/beamscale/.canary/cloud-credentials`

Those files must contain no real credentials or production identifiers. They exist only inside the synthetic tenant root and have no legitimate runtime use. Access is a high-confidence signal, but the policy remains monitor-only and records path/process metadata rather than file contents.

The Tetragon event by itself is not sufficient to quarantine anything. A BeamScale-owned sensor bridge must take the event PID and re-attribute it through host `/proc`, the managed cgroup subtree, and the root-owned runtime identity record. Events from unmanaged cgroups are ignored by the BeamScale containment path.

Do not add `Sigkill`, `Override`, `GetUrl`, or `DnsLookup` actions to these proving policies. Enforcement and alert delivery remain separate from the telemetry backend so switching Tetragon out for an in-tree CO-RE eBPF sensor does not change the containment contract. Tetragon policy mode stays `monitor`; freeze-first containment remains BeamScale-owned.

## Firecracker

Firecracker production nodes must keep the normal Firecracker security model intact:

- launch production VMMs through `jailer` or an equally restrictive launcher;
- keep Firecracker's default restrictive seccomp filters enabled;
- use a unique unprivileged UID/GID and unique BeamScale cgroup leaf per microVM;
- pin an approved Firecracker/jailer release and artifact digest rather than fetching `latest` at boot;
- reject debug/experimental binaries that lack the production default seccomp profile;
- ensure jailer input paths and their parent directories are root/operator controlled and not writable by tenant UIDs;
- do not mount the host honeypot AF_UNIX socket into a guest;
- use a host-owned vsock CID -> runtime-id registry for optional guest-originated canary evidence;
- monitor the host jailer/Firecracker cgroup so a guest-to-host breakout remains attributable even when guest canaries are bypassed.

A successful guest-to-host exploit may execute while the current host process is still `firecracker`; this is why unexpected VMM exec/namespace/ptrace/BPF behavior is monitored independently of guest wrappers.

## Rollout

1. Load all proving policies in monitoring mode on dedicated Ubuntu and Amazon Linux 2023 hosts.
2. Verify legitimate Hosted BEAM traffic does not emit child-process events.
3. Run a controlled fixture inside a managed BeamScale cgroup that attempts an absolute-path exec and one prohibited namespace syscall.
4. Materialize the non-secret decoy files only in a synthetic tenant root and verify a controlled read creates a sensor event without exposing contents.
5. Confirm the BeamScale bridge re-attributes the PID to the expected runtime and ignores identical events from unmanaged cgroups.
6. Confirm `bmscl-honeypot-daemon` freezes only that runtime cgroup and produces paired `detected`/`contained` receipts.
7. On a KVM-capable host, verify normal Firecracker startup is quiet after VMM launch, then run a controlled VMM-context sensor fixture and verify attribution to the exact microVM cgroup.
8. Run the same proof in `beamscale-test/bmscl-test-honeypot-containment-e2e` when funded runner capacity is available before promoting policy changes to production hosts.

Container-only CI validates syntax and policy invariants; it is not proof of eBPF, cgroup freeze, namespace escape, or Firecracker isolation behavior.
