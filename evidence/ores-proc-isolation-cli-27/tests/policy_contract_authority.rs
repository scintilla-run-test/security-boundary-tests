//! Cross-authority contract tests for the process-isolation policy schema.
//!
//! These tests keep the JSON Schema, TypeSpec authority, and checked-in
//! conformance corpus aligned on the security-sensitive policy vocabulary.

use std::fs;

#[test]
fn authored_policy_contracts_share_canonical_network_vocabulary() {
    let schema_text =
        fs::read_to_string("contracts/json-schema/contract.schema.json").expect("json schema");
    let schema: serde_json::Value = serde_json::from_str(&schema_text).expect("valid json schema");
    let typespec = fs::read_to_string("contracts/typespec/main.tsp").expect("typespec authority");

    let modes = schema["$defs"]["NetworkMode"]["enum"]
        .as_array()
        .expect("network mode enum");
    let schema_modes: Vec<_> = modes.iter().filter_map(|value| value.as_str()).collect();
    assert_eq!(schema_modes, vec!["none", "external", "local"]);

    for mode in ["none", "external", "local"] {
        assert!(
            typespec.contains(&format!(": \"{mode}\"")),
            "TypeSpec authority missing network mode {mode}"
        );
    }

    for declaration in [
        "PolicyName",
        "AbsolutePath",
        "CommandArgument",
        "Command",
        "NetworkMode",
        "FilesystemPolicy",
        "NetworkPolicy",
        "ResourceLimits",
        "Environment",
        "Group",
        "Process",
        "Groups",
        "Processes",
        "Defaults",
        "PolicyDocument",
    ] {
        assert!(
            schema["$defs"].get(declaration).is_some(),
            "JSON Schema authority missing named declaration {declaration}"
        );
        assert!(
            typespec.contains(declaration),
            "TypeSpec authority missing named declaration {declaration}"
        );
    }
}

#[test]
fn contract_instance_corpus_is_parseable_json() {
    for path in [
        "contracts/instances/PolicyDocument/valid/local-macos.json",
        "contracts/instances/PolicyDocument/invalid/relative-executable-shape.json",
        "conformance/cases/network-invariants.v1.json",
    ] {
        let text = fs::read_to_string(path).unwrap_or_else(|error| panic!("{path}: {error}"));
        serde_json::from_str::<serde_json::Value>(&text)
            .unwrap_or_else(|error| panic!("{path} is not valid JSON: {error}"));
    }
}
