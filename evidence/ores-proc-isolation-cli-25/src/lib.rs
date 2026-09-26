//! Independent compile/test harness for the exact production attestation source.

/// Minimal error surface matching the production module's dependency.
pub mod error {
    use thiserror::Error;

    /// Proof-harness result type.
    pub type Result<T> = std::result::Result<T, Error>;

    /// Minimal production-compatible error type used by the attestation module.
    #[derive(Debug, Error)]
    pub enum Error {
        /// Required Linux sandbox evidence was unavailable or invalid.
        #[error("sandbox unavailable: {0}")]
        SandboxUnavailable(String),
    }
}

#[path = "../linux_attestation.rs"]
pub mod linux_attestation;

pub use linux_attestation::{LinuxProcessAttestation, NamespaceEvidence, attest_linux_process};
