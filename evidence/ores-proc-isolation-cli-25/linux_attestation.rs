//! Fail-closed Linux process-boundary attestation for hosted tenant runtimes.
//!
//! This module does not create a sandbox. It verifies the security properties
//! that a trusted host controller must bind to a managed tenant process before
//! routing work to it. Callers must still bind the returned process start
//! identity to their systemd scope/cgroup and lifecycle fencing record.

#![allow(clippy::needless_return)]

use std::collections::BTreeMap;
use std::fs;
use std::path::{Path, PathBuf};

use serde::Serialize;

use crate::error::{Error, Result};

const REQUIRED_NAMESPACES: [&str; 7] = ["user", "mnt", "pid", "ipc", "uts", "cgroup", "net"];
const CAPABILITY_FIELDS: [&str; 5] = ["CapInh", "CapPrm", "CapEff", "CapBnd", "CapAmb"];

/// Host-vs-tenant namespace evidence captured from `/proc`.
#[derive(Debug, Clone, Serialize, PartialEq, Eq)]
pub struct NamespaceEvidence {
    /// Namespace identity visible for the trusted host verifier.
    pub host: String,
    /// Namespace identity visible for the tenant process.
    pub tenant: String,
}

/// Security evidence for one Linux tenant process.
#[derive(Debug, Clone, Serialize, PartialEq, Eq)]
pub struct LinuxProcessAttestation {
    /// Host PID that was inspected.
    pub pid: u32,
    /// Linux process start time in clock ticks from `/proc/<pid>/stat` field 22.
    /// This is part of the process identity and protects callers from PID reuse.
    pub process_start_ticks: u64,
    /// Unified cgroup-v2 path reported by the host procfs view.
    pub cgroup_v2_path: String,
    /// Verified `NoNewPrivs` state. Successful attestation always reports true.
    pub no_new_privs: bool,
    /// Verified capability state. Successful attestation always reports true.
    pub capabilities_zero: bool,
    /// Required namespace identities, keyed by namespace name.
    pub namespaces: BTreeMap<String, NamespaceEvidence>,
}

/// Verify one Linux tenant process against the mandatory hosted-runtime boundary.
///
/// The verifier fails closed unless all required namespaces differ from the host,
/// `NoNewPrivs` is set, all inherited/permitted/effective/bounding/ambient Linux
/// capability masks are zero, a cgroup-v2 path is visible, and the process start
/// identity remains stable for the entire inspection.
pub fn attest_linux_process(pid: u32) -> Result<LinuxProcessAttestation> {
    if !cfg!(target_os = "linux") {
        return Err(Error::SandboxUnavailable(
            "Linux process attestation is only available on Linux".to_owned(),
        ));
    }
    if pid == 0 {
        return Err(Error::SandboxUnavailable(
            "refusing to attest PID 0".to_owned(),
        ));
    }

    let proc_dir = PathBuf::from(format!("/proc/{pid}"));
    let start_before = read_process_start_ticks(&proc_dir)?;
    let status = fs::read_to_string(proc_dir.join("status")).map_err(|error| {
        Error::SandboxUnavailable(format!(
            "cannot read tenant process status for PID {pid}: {error}"
        ))
    })?;

    verify_no_new_privs(&status, pid)?;
    verify_zero_capabilities(&status, pid)?;
    let namespaces = verify_namespaces(&proc_dir, pid)?;
    let cgroup_v2_path = read_cgroup_v2_path(&proc_dir, pid)?;

    let start_after = read_process_start_ticks(&proc_dir)?;
    if start_before != start_after {
        return Err(Error::SandboxUnavailable(format!(
            "tenant PID {pid} changed identity during security attestation"
        )));
    }

    return Ok(LinuxProcessAttestation {
        pid,
        process_start_ticks: start_before,
        cgroup_v2_path,
        no_new_privs: true,
        capabilities_zero: true,
        namespaces,
    });
}

fn verify_no_new_privs(status: &str, pid: u32) -> Result<()> {
    let value = status_field(status, "NoNewPrivs").ok_or_else(|| {
        Error::SandboxUnavailable(format!("tenant PID {pid} status is missing NoNewPrivs"))
    })?;
    if value != "1" {
        return Err(Error::SandboxUnavailable(format!(
            "tenant PID {pid} is not fail-closed: expected NoNewPrivs=1, found {value:?}"
        )));
    }
    return Ok(());
}

fn verify_zero_capabilities(status: &str, pid: u32) -> Result<()> {
    for field in CAPABILITY_FIELDS {
        let value = status_field(status, field).ok_or_else(|| {
            Error::SandboxUnavailable(format!("tenant PID {pid} status is missing {field}"))
        })?;
        let mask = u128::from_str_radix(value, 16).map_err(|error| {
            Error::SandboxUnavailable(format!(
                "tenant PID {pid} has invalid {field} capability mask {value:?}: {error}"
            ))
        })?;
        if mask != 0 {
            return Err(Error::SandboxUnavailable(format!(
                "tenant PID {pid} is not fail-closed: expected zero Linux capability sets, {field}={value}"
            )));
        }
    }
    return Ok(());
}

fn verify_namespaces(proc_dir: &Path, pid: u32) -> Result<BTreeMap<String, NamespaceEvidence>> {
    let mut evidence = BTreeMap::new();
    for namespace in REQUIRED_NAMESPACES {
        let host = namespace_identity(
            Path::new("/proc/self/ns").join(namespace),
            "host",
            namespace,
        )?;
        let tenant = namespace_identity(
            proc_dir.join("ns").join(namespace),
            &format!("tenant PID {pid}"),
            namespace,
        )?;
        if host == tenant {
            return Err(Error::SandboxUnavailable(format!(
                "tenant PID {pid} shares the host {namespace} namespace ({tenant})"
            )));
        }
        evidence.insert(namespace.to_owned(), NamespaceEvidence { host, tenant });
    }
    return Ok(evidence);
}

fn namespace_identity(path: PathBuf, owner: &str, namespace: &str) -> Result<String> {
    let target = fs::read_link(&path).map_err(|error| {
        Error::SandboxUnavailable(format!(
            "cannot read {owner} {namespace} namespace identity {}: {error}",
            path.display()
        ))
    })?;
    let identity = target.to_string_lossy().into_owned();
    if identity.trim().is_empty() {
        return Err(Error::SandboxUnavailable(format!(
            "{owner} {namespace} namespace identity is empty"
        )));
    }
    return Ok(identity);
}

fn read_cgroup_v2_path(proc_dir: &Path, pid: u32) -> Result<String> {
    let text = fs::read_to_string(proc_dir.join("cgroup")).map_err(|error| {
        Error::SandboxUnavailable(format!(
            "cannot read cgroup identity for tenant PID {pid}: {error}"
        ))
    })?;
    let mut matches = text.lines().filter_map(|line| line.strip_prefix("0::"));
    let path = matches.next().ok_or_else(|| {
        Error::SandboxUnavailable(format!(
            "tenant PID {pid} has no unified cgroup-v2 membership"
        ))
    })?;
    if matches.next().is_some() || !path.starts_with('/') {
        return Err(Error::SandboxUnavailable(format!(
            "tenant PID {pid} has ambiguous cgroup-v2 membership"
        )));
    }
    return Ok(path.to_owned());
}

fn read_process_start_ticks(proc_dir: &Path) -> Result<u64> {
    let stat_path = proc_dir.join("stat");
    let text = fs::read_to_string(&stat_path).map_err(|error| {
        Error::SandboxUnavailable(format!(
            "cannot read process identity {}: {error}",
            stat_path.display()
        ))
    })?;
    return parse_process_start_ticks(&text).ok_or_else(|| {
        Error::SandboxUnavailable(format!(
            "cannot parse process start identity {}",
            stat_path.display()
        ))
    });
}

fn parse_process_start_ticks(stat: &str) -> Option<u64> {
    let command_end = stat.rfind(')')?;
    let remainder = stat.get(command_end + 1..)?.trim();
    // The first token after `comm` is field 3 (`state`). Field 22 (`starttime`)
    // is therefore token index 19 in this remainder.
    return remainder.split_whitespace().nth(19)?.parse().ok();
}

fn status_field<'a>(status: &'a str, field: &str) -> Option<&'a str> {
    return status.lines().find_map(|line| {
        let (name, value) = line.split_once(':')?;
        if name == field {
            return Some(value.trim());
        }
        return None;
    });
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn parses_start_ticks_when_process_name_contains_spaces_and_parentheses() {
        let stat =
            "4242 (tenant (beam) vm) S 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 987654 20";
        assert_eq!(parse_process_start_ticks(stat), Some(987654));
    }

    #[test]
    fn status_field_requires_exact_field_name() {
        let status = "NoNewPrivs:\t1\nCapEff:\t0000000000000000\n";
        assert_eq!(status_field(status, "NoNewPrivs"), Some("1"));
        assert_eq!(status_field(status, "CapEff"), Some("0000000000000000"));
        assert_eq!(status_field(status, "Cap"), None);
    }

    #[test]
    fn nonzero_capability_mask_fails_closed() {
        let status = concat!(
            "CapInh:\t0000000000000000\n",
            "CapPrm:\t0000000000000000\n",
            "CapEff:\t0000000000000001\n",
            "CapBnd:\t0000000000000000\n",
            "CapAmb:\t0000000000000000\n",
        );
        assert!(verify_zero_capabilities(status, 99).is_err());
    }

    #[test]
    fn no_new_privs_must_be_one() {
        assert!(verify_no_new_privs("NoNewPrivs:\t0\n", 99).is_err());
        assert!(verify_no_new_privs("NoNewPrivs:\t1\n", 99).is_ok());
        assert!(verify_no_new_privs("", 99).is_err());
    }
}
