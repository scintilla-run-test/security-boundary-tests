//! Fail-closed binding between Linux process attestation and a trusted host runtime record.
//!
//! Attestation proves properties of the process that currently occupies a host PID.
//! It does not, by itself, prove that the process is the runtime the scheduler meant
//! to inspect. The trusted host controller must bind the evidence to identity it
//! recorded when it created the managed scope/cgroup.

#![allow(clippy::needless_return)]

use serde::{Deserialize, Serialize};

use crate::error::{Error, Result};
use crate::linux_attestation::{LinuxProcessAttestation, attest_linux_process};

/// Host-owned identity recorded when a managed Linux tenant runtime is created.
///
/// This value must come from trusted controller state, never from tenant input.
#[derive(Debug, Clone, Deserialize, Serialize, PartialEq, Eq)]
pub struct ExpectedLinuxRuntimeIdentity {
    /// Host PID assigned to the managed tenant runtime.
    pub pid: u32,
    /// `/proc/<pid>/stat` start-time field captured for the managed process.
    pub process_start_ticks: u64,
    /// Exact unified cgroup-v2 path assigned by the trusted host controller.
    pub cgroup_v2_path: String,
}

/// Attest a Linux process and bind the result to the expected host-owned runtime identity.
pub fn attest_and_bind_linux_runtime(
    expected: &ExpectedLinuxRuntimeIdentity,
) -> Result<LinuxProcessAttestation> {
    validate_expected_identity(expected)?;
    let attestation = attest_linux_process(expected.pid)?;
    verify_linux_runtime_binding(&attestation, expected)?;
    return Ok(attestation);
}

/// Verify that attestation evidence belongs to exactly the expected managed runtime.
///
/// PID, process start identity, and cgroup-v2 path must all match. Checking all
/// three prevents a reused naked PID, a valid sandbox in the wrong tenant cgroup,
/// or stale controller state from being accepted as authority for lifecycle work.
pub fn verify_linux_runtime_binding(
    attestation: &LinuxProcessAttestation,
    expected: &ExpectedLinuxRuntimeIdentity,
) -> Result<()> {
    validate_expected_identity(expected)?;

    if attestation.pid != expected.pid {
        return Err(Error::SandboxUnavailable(format!(
            "tenant runtime PID mismatch: expected {}, attested {}",
            expected.pid, attestation.pid
        )));
    }
    if attestation.process_start_ticks != expected.process_start_ticks {
        return Err(Error::SandboxUnavailable(format!(
            "tenant runtime process identity changed for PID {}: expected start {}, attested {}",
            expected.pid, expected.process_start_ticks, attestation.process_start_ticks
        )));
    }
    if attestation.cgroup_v2_path != expected.cgroup_v2_path {
        return Err(Error::SandboxUnavailable(format!(
            "tenant runtime cgroup mismatch for PID {}: expected {:?}, attested {:?}",
            expected.pid, expected.cgroup_v2_path, attestation.cgroup_v2_path
        )));
    }

    return Ok(());
}

fn validate_expected_identity(expected: &ExpectedLinuxRuntimeIdentity) -> Result<()> {
    if expected.pid == 0 {
        return Err(Error::SandboxUnavailable(
            "trusted runtime identity may not use PID 0".to_owned(),
        ));
    }
    if expected.process_start_ticks == 0 {
        return Err(Error::SandboxUnavailable(format!(
            "trusted runtime identity for PID {} has an invalid zero process start time",
            expected.pid
        )));
    }
    if !expected.cgroup_v2_path.starts_with('/') || expected.cgroup_v2_path == "/" {
        return Err(Error::SandboxUnavailable(format!(
            "trusted runtime identity for PID {} has an unsafe cgroup-v2 path {:?}",
            expected.pid, expected.cgroup_v2_path
        )));
    }

    return Ok(());
}

#[cfg(test)]
mod tests {
    use std::collections::BTreeMap;

    use super::*;
    use crate::linux_attestation::NamespaceEvidence;

    fn expected() -> ExpectedLinuxRuntimeIdentity {
        return ExpectedLinuxRuntimeIdentity {
            pid: 4242,
            process_start_ticks: 987_654,
            cgroup_v2_path: "/beamscale/tenant-a/runtime-7".to_owned(),
        };
    }

    fn attestation() -> LinuxProcessAttestation {
        return LinuxProcessAttestation {
            pid: 4242,
            process_start_ticks: 987_654,
            cgroup_v2_path: "/beamscale/tenant-a/runtime-7".to_owned(),
            no_new_privs: true,
            capabilities_zero: true,
            namespaces: BTreeMap::<String, NamespaceEvidence>::new(),
        };
    }

    #[test]
    fn exact_runtime_identity_is_accepted() {
        assert!(verify_linux_runtime_binding(&attestation(), &expected()).is_ok());
    }

    #[test]
    fn pid_mismatch_fails_closed() {
        let mut evidence = attestation();
        evidence.pid = 4243;
        assert!(verify_linux_runtime_binding(&evidence, &expected()).is_err());
    }

    #[test]
    fn pid_reuse_start_time_mismatch_fails_closed() {
        let mut evidence = attestation();
        evidence.process_start_ticks += 1;
        assert!(verify_linux_runtime_binding(&evidence, &expected()).is_err());
    }

    #[test]
    fn wrong_tenant_cgroup_fails_closed() {
        let mut evidence = attestation();
        evidence.cgroup_v2_path = "/beamscale/tenant-b/runtime-7".to_owned();
        assert!(verify_linux_runtime_binding(&evidence, &expected()).is_err());
    }

    #[test]
    fn root_cgroup_is_never_a_valid_managed_runtime_identity() {
        let mut identity = expected();
        identity.cgroup_v2_path = "/".to_owned();
        assert!(verify_linux_runtime_binding(&attestation(), &identity).is_err());
    }

    #[test]
    fn zero_start_identity_is_rejected() {
        let mut identity = expected();
        identity.process_start_ticks = 0;
        assert!(verify_linux_runtime_binding(&attestation(), &identity).is_err());
    }
}
