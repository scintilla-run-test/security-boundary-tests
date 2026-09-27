//! High-level command execution.

use std::collections::BTreeMap;
use std::io::{self, Read};

use serde::Serialize;

use crate::config::Config;
use crate::error::{Error, Result};
use crate::flags::{Cli, CliCommand};
use crate::platform::{self, SandboxPlan};

const MAX_TARGET_ENV_STDIN_BYTES: u64 = 256 * 1024;
const MAX_TARGET_ENV_KEYS: usize = 512;

/// Execute one parsed CLI invocation and return the desired process exit code.
pub fn run(cli: Cli) -> Result<i32> {
    let config = Config::load(&cli.config_path)?;

    match cli.command {
        CliCommand::Check => {
            let report = CheckReport {
                ok: true,
                config: cli.config_path.display().to_string(),
                version: config.version,
                groups: config.groups.len(),
                processes: config.processes.len(),
                beamscale_honeypot: cli.beamscale_honeypot,
            };
            emit(&report, cli.json, || {
                format!(
                    "policy ok: {} group(s), {} process(es), schema v{}, beamscale_honeypot={}",
                    report.groups, report.processes, report.version, report.beamscale_honeypot
                )
            })?;
            Ok(0)
        }
        CliCommand::Doctor => {
            let report = platform::doctor(&config, cli.beamscale_honeypot);
            let ok = report.ok;
            emit(&report, cli.json, || {
                let mut text = format!(
                    "backend={} platform={} status={}\n",
                    report.backend,
                    report.platform,
                    if report.ok { "ok" } else { "not-ready" }
                );
                for check in &report.checks {
                    text.push_str(&format!(
                        "  [{}] {}: {}\n",
                        if check.available { "ok" } else { "missing" },
                        check.name,
                        check.detail
                    ));
                }
                for note in &report.notes {
                    text.push_str(&format!("  note: {note}\n"));
                }
                text.trim_end().to_owned()
            })?;
            Ok(if ok { 0 } else { 2 })
        }
        CliCommand::Explain { process } => {
            let resolved = config.resolve_process(&process, None)?;
            let members = config.processes_for_group(&resolved.group)?;
            let report = ExplainReport {
                process: resolved.name,
                group: resolved.group,
                executable: resolved.executable.display().to_string(),
                working_directory: resolved
                    .working_directory
                    .as_ref()
                    .map(|path| path.display().to_string()),
                fixed_args: resolved.args,
                read_only: resolved
                    .policy
                    .filesystem
                    .read_only
                    .iter()
                    .map(|path| path.display().to_string())
                    .collect(),
                read_write: resolved
                    .policy
                    .filesystem
                    .read_write
                    .iter()
                    .map(|path| path.display().to_string())
                    .collect(),
                network: resolved.policy.network,
                limits: resolved.policy.limits,
                environment_keys: resolved.environment.keys().cloned().collect(),
                group_members: members,
                beamscale_honeypot: cli.beamscale_honeypot,
            };
            emit(&report, cli.json, || {
                format!(
                    "process={} group={} executable={} members=[{}] beamscale_honeypot={}",
                    report.process,
                    report.group,
                    report.executable,
                    report.group_members.join(","),
                    report.beamscale_honeypot
                )
            })?;
            Ok(0)
        }
        CliCommand::Run {
            process,
            extra_args,
        } => {
            let launch_environment = if cli.target_env_stdin {
                read_target_environment(io::stdin().lock())?
            } else {
                BTreeMap::new()
            };
            let resolved =
                config.resolve_process_with_environment(&process, None, &launch_environment)?;
            let plan = platform::prepare_plan(resolved, &extra_args, cli.beamscale_honeypot)?;
            if cli.dry_run {
                emit_plan(&plan, cli.json)?;
                return Ok(0);
            }
            platform::launch(&plan)
        }
    }
}

fn read_target_environment(reader: impl Read) -> Result<BTreeMap<String, String>> {
    let mut bytes = Vec::new();
    reader
        .take(MAX_TARGET_ENV_STDIN_BYTES + 1)
        .read_to_end(&mut bytes)
        .map_err(Error::HelperIo)?;
    if bytes.len() as u64 > MAX_TARGET_ENV_STDIN_BYTES {
        return Err(Error::Cli(format!(
            "target environment stdin exceeds {} bytes",
            MAX_TARGET_ENV_STDIN_BYTES
        )));
    }

    let environment: BTreeMap<String, String> =
        serde_json::from_slice(&bytes).map_err(|error| {
            Error::Cli(format!(
                "target environment stdin must be a JSON object of string values: {error}"
            ))
        })?;
    if environment.len() > MAX_TARGET_ENV_KEYS {
        return Err(Error::Cli(format!(
            "target environment stdin exceeds {} keys",
            MAX_TARGET_ENV_KEYS
        )));
    }
    Ok(environment)
}

fn emit_plan(plan: &SandboxPlan, json: bool) -> Result<()> {
    emit(plan, json, || {
        format!(
            "dry-run: backend={} process={} group={} executable={} args={:?} read_only={} env_keys={:?} beamscale_honeypot={}",
            plan.backend,
            plan.process,
            plan.group,
            plan.executable.display(),
            plan.args,
            plan.read_only.len(),
            plan.environment_keys,
            plan.beamscale_honeypot
        )
    })
}

fn emit<T, F>(value: &T, json: bool, plain: F) -> Result<()>
where
    T: Serialize,
    F: FnOnce() -> String,
{
    if json {
        println!("{}", serde_json::to_string(value)?);
    } else {
        println!("{}", plain());
    }
    Ok(())
}

#[derive(Debug, Serialize)]
struct CheckReport {
    ok: bool,
    config: String,
    version: u32,
    groups: usize,
    processes: usize,
    beamscale_honeypot: bool,
}

#[derive(Debug, Serialize)]
struct ExplainReport {
    process: String,
    group: String,
    executable: String,
    working_directory: Option<String>,
    fixed_args: Vec<String>,
    read_only: Vec<String>,
    read_write: Vec<String>,
    network: crate::config::NetworkPolicy,
    limits: crate::config::ResourceLimits,
    environment_keys: Vec<String>,
    group_members: Vec<String>,
    beamscale_honeypot: bool,
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::io::Cursor;

    #[test]
    fn target_environment_stdin_is_bounded_and_string_typed() {
        let parsed = read_target_environment(Cursor::new(br#"{"MODE":"safe","TOKEN":"secret"}"#))
            .expect("valid overlay");
        assert_eq!(parsed["MODE"], "safe");
        assert_eq!(parsed["TOKEN"], "secret");

        assert!(read_target_environment(Cursor::new(br#"{"MODE":7}"#)).is_err());

        let oversized = vec![b'x'; MAX_TARGET_ENV_STDIN_BYTES as usize + 1];
        assert!(read_target_environment(Cursor::new(oversized)).is_err());
    }

    #[test]
    fn target_environment_stdin_key_count_is_bounded() {
        let mut values = BTreeMap::new();
        for index in 0..=MAX_TARGET_ENV_KEYS {
            values.insert(format!("K{index}"), "v".to_owned());
        }
        let encoded = serde_json::to_vec(&values).expect("encode");
        assert!(read_target_environment(Cursor::new(encoded)).is_err());
    }
}
