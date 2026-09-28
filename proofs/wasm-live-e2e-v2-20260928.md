# WASM live E2E v2

Live-only retry after identifying that the first harness killed its daemon at the end of the startup shell step. This version keeps daemon startup, doctor, receipt deploy, tamper checks, immutable-ID checks, partial-evidence rejection, and weak/symlink token checks inside one shell lifetime.
