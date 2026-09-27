//! Independent compile/test harness for the exact production attestation and runtime-binding sources.

/// Minimal error surface matching the production modules' dependency.
pub mod error {
    use thiserror::Error;

    /// Proof-harness result type.
    pub type Result<T> = std::result::Result<T, Error>;

    /// Minimal production-compatible error type used by the isolation modules.
    #[derive(Debug, Error)]
    pub enum Error {
        /// Required Linux sandbox evidence was unavailable or invalid.
        #[error("sandbox unavailable: {0}")]
        SandboxUnavailable(String),
    }
}

#[path = "../linux_attestation.rs"]
pub mod linux_attestation;
#[path = "../linux_runtime_binding.rs"]
pub mod linux_runtime_binding;

pub use linux_attestation::{LinuxProcessAttestation, NamespaceEvidence, attest_linux_process};
pub use linux_runtime_binding::{
    ExpectedLinuxRuntimeIdentity, attest_and_bind_linux_runtime, verify_linux_runtime_binding,
};
