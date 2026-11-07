// SPDX-FileCopyrightText: 2026 Mattia Egloff <mattia.egloff@pm.me>
// SPDX-License-Identifier: GPL-3.0-or-later

use std::{io, process::ExitCode};
use vauchi_architecture_check::complexity::{analyze_sources, SourceFile};

fn run() -> Result<u8, String> {
    let files: Vec<SourceFile> = serde_json::from_reader(io::stdin().lock())
        .map_err(|error| format!("invalid source request: {error}"))?;
    let report = analyze_sources(&files);
    serde_json::to_writer(io::stdout().lock(), &report).map_err(|error| error.to_string())?;
    Ok(if report.failures.is_empty() { 0 } else { 2 })
}

fn main() -> ExitCode {
    match run() {
        Ok(code) => ExitCode::from(code),
        Err(error) => {
            eprintln!("quality-complexity: {error}");
            ExitCode::from(2)
        }
    }
}
