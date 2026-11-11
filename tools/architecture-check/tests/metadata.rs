// SPDX-FileCopyrightText: 2026 Mattia Egloff <mattia.egloff@pm.me>
// SPDX-License-Identifier: GPL-3.0-or-later

use serde_json::json;
use std::fs;
use tempfile::TempDir;
use vauchi_architecture_check::analyze_with_generated;

fn fixture(custom: bool) -> TempDir {
    let root = TempDir::new().unwrap();
    let mut packages = vec![];
    for name in ["vauchi-core", "vauchi-app"] {
        let dir = root.path().join(name);
        fs::create_dir_all(dir.join("src")).unwrap();
        fs::write(dir.join("Cargo.toml"), "").unwrap();
        fs::write(
            dir.join("src/lib.rs"),
            if name == "vauchi-core" {
                "fn f(_: renamed::App) {}"
            } else {
                "pub struct App;"
            },
        )
        .unwrap();
        fs::write(dir.join("src/entry.rs"), "pub struct App;").unwrap();
        packages.push(json!({"id":name, "name":name, "manifest_path":dir.join("Cargo.toml"),
            "targets":[{"name":name.replace('-', "_"), "kind":["lib"], "src_path":dir.join(if custom {"src/entry.rs"} else {"src/lib.rs"})}],
            "dependencies":if name=="vauchi-core" {vec![json!({"name":"vauchi-app","rename":"renamed","kind":null})]} else {vec![]}}));
    }
    fs::write(
        root.path().join("cargo-metadata.json"),
        serde_json::to_vec(
            &json!({"packages":packages,"workspace_members":["vauchi-core","vauchi-app"]}),
        )
        .unwrap(),
    )
    .unwrap();
    root
}

// @internal — manifest dependency aliases retain their real crate direction.
#[test]
fn cargo_dependency_alias_is_resolved() {
    let root = fixture(false);
    let report = analyze_with_generated(root.path(), Some(root.path())).unwrap();
    assert!(report
        .references
        .iter()
        .any(|r| r.target == "vauchi-app/lib"));
}

// @internal — unsupported Cargo library roots fail instead of scanning decoys.
#[test]
fn custom_cargo_root_fails_closed() {
    let root = fixture(true);
    assert!(analyze_with_generated(root.path(), Some(root.path()))
        .unwrap_err()
        .contains("library root"));
}

fn workspace_with(names: &[&str], normal_deps: &[(&str, &str)]) -> TempDir {
    let root = TempDir::new().unwrap();
    let mut packages = vec![];
    for name in names {
        let dir = root.path().join(name);
        fs::create_dir_all(dir.join("src")).unwrap();
        fs::write(dir.join("Cargo.toml"), "").unwrap();
        fs::write(dir.join("src/lib.rs"), "pub struct Item;").unwrap();
        let deps: Vec<_> = normal_deps
            .iter()
            .filter(|(from, _)| from == name)
            .map(|(_, to)| json!({"name": to, "rename": null, "kind": null}))
            .collect();
        packages.push(json!({"id":name, "name":name, "manifest_path":dir.join("Cargo.toml"),
            "targets":[{"name":name.replace('-', "_"), "kind":["lib"], "src_path":dir.join("src/lib.rs")}],
            "dependencies":deps}));
    }
    fs::write(
        root.path().join("cargo-metadata.json"),
        serde_json::to_vec(&json!({"packages":packages,"workspace_members":names})).unwrap(),
    )
    .unwrap();
    root
}

// @internal — core's test-helper crate is an accepted workspace member that
// is not analysed as production code: it exists to call test-only APIs
// (vauchi/private#1230).
#[test]
fn core_testkit_is_accepted_and_not_scanned_as_production() {
    let root = workspace_with(&["vauchi-core", "vauchi-core-testkit"], &[]);
    let report = analyze_with_generated(root.path(), Some(root.path())).unwrap();
    assert!(report.modules.contains("vauchi-core/lib"));
    assert!(!report
        .modules
        .iter()
        .any(|m| m.starts_with("vauchi-core-testkit/")));
}

// @internal — production must never reach the test helpers: a library that
// depends on the testkit outside dev-dependencies fails.
#[test]
fn a_normal_dependency_on_the_testkit_fails() {
    let root = workspace_with(
        &["vauchi-core", "vauchi-core-testkit"],
        &[("vauchi-core", "vauchi-core-testkit")],
    );
    assert_eq!(
        analyze_with_generated(root.path(), Some(root.path())).unwrap_err(),
        "vauchi-core depends on test-only crate vauchi-core-testkit outside dev-dependencies"
    );
}

// @internal — the allowlist stays closed: a crate nobody added still fails.
#[test]
fn an_unlisted_workspace_crate_still_fails() {
    let root = workspace_with(&["vauchi-core", "vauchi-unlisted"], &[]);
    assert_eq!(
        analyze_with_generated(root.path(), Some(root.path())).unwrap_err(),
        "unsupported workspace crate: vauchi-unlisted"
    );
}
