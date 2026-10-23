// SPDX-FileCopyrightText: 2026 Mattia Egloff <mattia.egloff@pm.me>
// SPDX-License-Identifier: GPL-3.0-or-later

use std::{collections::BTreeSet, fs, process::Command};
use tempfile::TempDir;
use vauchi_architecture_check::{
    policy::{self, Allowance, Baseline, Policy},
    Reference, Report,
};

fn policy() -> Policy {
    serde_json::from_str(r#"{"schema_version":1,"crates":{"vauchi-core":1},"layers":{"vauchi-core/lib":5,"vauchi-core/domain":1,"vauchi-core/storage":4,"vauchi-core/api":5},"compatibility_modules":[]}"#).unwrap()
}

fn report(caller: &str) -> Report {
    Report {
        modules: BTreeSet::from([
            "vauchi-core/lib".into(),
            "vauchi-core/domain".into(),
            "vauchi-core/storage".into(),
        ]),
        references: BTreeSet::from([Reference {
            source: "vauchi-core/domain".into(),
            target: "vauchi-core/storage".into(),
            file: "vauchi-core/src/domain.rs".into(),
            owner: caller.into(),
            symbol: "vauchi_core::storage::Storage".into(),
            via: Default::default(),
            line: 1,
            column: 1,
        }]),
        ..Report::default()
    }
}

fn empty_baseline() -> Baseline {
    Baseline {
        schema_version: 1,
        exceptions: Default::default(),
        apis: Default::default(),
    }
}

// @internal — seeded forbidden-edge test of the gate's public API.
#[test]
fn seeded_upward_edge_fails_and_removing_it_passes() {
    let mut r = report("domain::old");
    let errors = policy::check(&r, &policy(), &empty_baseline()).unwrap_err();
    assert!(errors.join("\n").contains("domain"));
    assert!(errors.join("\n").contains("storage"));
    r.references.clear();
    assert_eq!(policy::check(&r, &policy(), &empty_baseline()), Ok(()));
}

// @internal — equal totals cannot hide a new caller.
#[test]
fn replacing_one_legacy_caller_with_another_still_fails() {
    let old = report("domain::old");
    let mut baseline = empty_baseline();
    for (key, count) in policy::violations(&old, &policy()).unwrap() {
        baseline.exceptions.insert(
            key,
            Allowance {
                count,
                issue: "#765".into(),
                reason: "migration".into(),
            },
        );
    }
    assert_eq!(policy::check(&old, &policy(), &baseline), Ok(()));
    assert!(policy::check(&report("domain::new"), &policy(), &baseline).is_err());
}

// @internal — invalid coverage/configuration must not pass as zero violations.
#[test]
fn unknown_module_missing_crate_and_invalid_version_fail() {
    let mut r = report("domain::old");
    r.modules.insert("vauchi-core/new_module".into());
    assert!(policy::violations(&r, &policy())
        .unwrap_err()
        .contains("new_module"));
    let mut p = policy();
    p.crates.insert("vauchi-app".into(), 2);
    assert!(policy::violations(&report("old"), &p)
        .unwrap_err()
        .contains("vauchi-app"));
    p = policy();
    p.schema_version = 99;
    assert!(policy::violations(&report("old"), &p)
        .unwrap_err()
        .contains("version"));
}

// @internal — baseline edits cannot authorize a violation.
#[test]
fn baseline_widening_and_new_api_identity_fail() {
    let before = empty_baseline();
    let mut after = empty_baseline();
    after.apis.insert("DomainCommand::NewDomain".into());
    assert!(policy::validate_tightening(&before, &after).is_err());
    let mut r = Report {
        modules: BTreeSet::from(["vauchi-core/lib".into()]),
        ..Report::default()
    };
    r.apis = after.apis.clone();
    assert!(policy::check(&r, &policy(), &before)
        .unwrap_err()
        .join("\n")
        .contains("NewDomain"));
}

// @internal — actual process status, not only library predicates.
#[test]
fn executable_fails_for_missing_files_and_forbidden_edge() {
    let binary = env!("CARGO_BIN_EXE_vauchi-architecture-check");
    let missing = Command::new(binary)
        .args(["check", "/missing", "/missing", "/missing"])
        .output()
        .unwrap();
    assert_eq!(missing.status.code(), Some(2));
    let temp = TempDir::new().unwrap();
    let src = temp.path().join("vauchi-core/src");
    fs::create_dir_all(&src).unwrap();
    fs::write(src.join("lib.rs"), "mod domain; mod storage;").unwrap();
    fs::write(src.join("domain.rs"), "use crate::storage::Storage;").unwrap();
    fs::write(src.join("storage.rs"), "pub struct Storage;").unwrap();
    let config = temp.path().join("policy.json");
    let baseline = temp.path().join("baseline.json");
    fs::write(&config, serde_json::to_vec(&policy()).unwrap()).unwrap();
    fs::write(&baseline, serde_json::to_vec(&empty_baseline()).unwrap()).unwrap();
    let result = Command::new(binary)
        .arg("check")
        .arg(temp.path())
        .arg(&config)
        .arg(&baseline)
        .output()
        .unwrap();
    assert_eq!(result.status.code(), Some(1));
    assert!(String::from_utf8(result.stderr).unwrap().contains("VRS06"));
    fs::write(src.join("domain.rs"), "pub struct Domain;").unwrap();
    let result = Command::new(binary)
        .arg("check")
        .arg(temp.path())
        .arg(&config)
        .arg(&baseline)
        .output()
        .unwrap();
    assert_eq!(result.status.code(), Some(0));
}

// @internal — an external glob must neither recurse forever nor hide a local edge.
#[test]
fn external_glob_resolution_terminates() {
    let temp = TempDir::new().unwrap();
    let src = temp.path().join("vauchi-core/src");
    fs::create_dir_all(&src).unwrap();
    fs::write(src.join("lib.rs"), "mod domain; mod storage;").unwrap();
    fs::write(
        src.join("domain.rs"),
        "use base64::prelude::*; use crate::storage::Storage;",
    )
    .unwrap();
    fs::write(src.join("storage.rs"), "pub struct Storage;").unwrap();
    let mut child = Command::new(env!("CARGO_BIN_EXE_vauchi-architecture-check"))
        .arg("scan")
        .arg(temp.path())
        .stdout(std::process::Stdio::piped())
        .spawn()
        .unwrap();
    let deadline = std::time::Instant::now() + std::time::Duration::from_secs(2);
    loop {
        if child.try_wait().unwrap().is_some() {
            break;
        }
        if std::time::Instant::now() >= deadline {
            child.kill().unwrap();
            child.wait().unwrap();
            panic!("external glob resolution did not terminate");
        }
        std::thread::sleep(std::time::Duration::from_millis(10));
    }
    let output = child.wait_with_output().unwrap();
    assert!(output.status.success());
    let report: Report = serde_json::from_slice(&output.stdout).unwrap();
    assert!(report
        .references
        .iter()
        .any(|r| r.source == "vauchi-core/domain" && r.target == "vauchi-core/storage"));
}
