// SPDX-FileCopyrightText: 2026 Mattia Egloff <mattia.egloff@pm.me>
// SPDX-License-Identifier: GPL-3.0-or-later

use serde::de::DeserializeOwned;
use std::{env, fs, path::Path, process::ExitCode};
use vauchi_architecture_check::{
    analyze_with_generated,
    policy::{self, Baseline, Policy},
};

fn read<T: DeserializeOwned>(path: &str) -> Result<T, String> {
    let bytes = fs::read(path).map_err(|e| format!("{path}: {e}"))?;
    serde_json::from_slice(&bytes).map_err(|e| format!("{path}: {e}"))
}

fn run(args: &[String]) -> Result<u8, String> {
    let generated = env::var_os("VAUCHI_ARCHITECTURE_GENERATED_DIR");
    let generated = generated.as_deref().map(Path::new);
    match args {
        [command, root] if command == "scan" => {
            let report = analyze_with_generated(Path::new(root), generated)?;
            println!("{}", serde_json::to_string_pretty(&report).map_err(|e| e.to_string())?);
            Ok(0)
        }
        [command, root, config, baseline, rest @ ..] if command == "check" && rest.len() <= 2 => {
            let policy: Policy = read(config)?;
            let baseline: Baseline = read(baseline)?;
            if let Some(previous) = rest.first() {
                policy::validate_tightening(&read(previous)?, &baseline)?;
            }
            if let Some(previous) = rest.get(1) {
                policy::validate_policy_tightening(&read(previous)?, &policy)?;
            }
            let report = analyze_with_generated(Path::new(root), generated)?;
            // Invalid coverage is an operational error, not an accepted empty graph.
            policy::violations(&report, &policy)?;
            match policy::check(&report, &policy, &baseline) {
                Ok(()) => Ok(0),
                Err(errors) => {
                    eprintln!("{}", errors.join("\n"));
                    Ok(1)
                }
            }
        }
        _ => Err("usage: vauchi-architecture-check scan ROOT | check ROOT POLICY BASELINE [PREVIOUS_BASELINE [PREVIOUS_POLICY]]".into()),
    }
}

fn main() -> ExitCode {
    match run(&env::args().skip(1).collect::<Vec<_>>()) {
        Ok(code) => ExitCode::from(code),
        Err(error) => {
            eprintln!("VRS06: architecture check could not complete: {error}");
            ExitCode::from(2)
        }
    }
}
