//! Live negative proof for the hosted-tenant Linux attestation boundary.

#[cfg(target_os = "linux")]
#[test]
fn ordinary_runner_process_is_not_tenant_ready() {
    let result = ores_proc_isolation_attestation_proof::attest_linux_process(std::process::id());
    assert!(
        result.is_err(),
        "a process sharing the CI runner namespaces must never attest as a tenant sandbox"
    );
}
