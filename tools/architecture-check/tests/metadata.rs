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
