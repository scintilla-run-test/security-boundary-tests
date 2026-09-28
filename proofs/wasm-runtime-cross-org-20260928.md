# WASM runtime cross-org proof

This branch spends `scintilla-run-test` GitHub Actions minutes to validate the current wasm-xprs and Lunatic Lorry desktop runtime chain without consuming product-org Actions budget.

The workflow composes the open wasm-xprs receipt-handoff and unique-port CLI changes in-run, tests them against the merged daemon, exercises valid and tampered ORES receipt evidence, proves immutable deployment identity and token-file fail-closed behavior, and reruns release suites across Linux, macOS, and Windows.
