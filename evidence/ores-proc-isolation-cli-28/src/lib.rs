//! Rootless, fail-closed process isolation for macOS and Linux.
//!
//! The crate intentionally splits policy resolution (Rust) from OS sandbox
//! mechanics (small reviewed shell helpers). Public CLI parsing is delegated to
//! `flags-2-env`; process/group resolution uses `ores-reactive-maps`.

pub mod config;
pub mod error;
pub mod flags;
pub mod linux_attestation;
pub mod linux_runtime_binding;
pub mod platform;
pub mod runner;

pub use config::{Config, ResolvedProcess};
pub use error::{Error, Result};
pub use linux_attestation::{LinuxProcessAttestation, NamespaceEvidence, attest_linux_process};
pub use linux_runtime_binding::{
    ExpectedLinuxRuntimeIdentity, attest_and_bind_linux_runtime, verify_linux_runtime_binding,
};
