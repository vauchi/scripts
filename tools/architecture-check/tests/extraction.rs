// SPDX-FileCopyrightText: 2026 Mattia Egloff <mattia.egloff@pm.me>
// SPDX-License-Identifier: GPL-3.0-or-later

use std::{collections::BTreeSet, fs, path::Path};
use tempfile::TempDir;
use vauchi_architecture_check::{analyze, analyze_with_generated, Report};

fn fixture(files: &[(&str, &str)]) -> TempDir {
    let temp = TempDir::new().unwrap();
    for (name, source) in files {
        let file = temp.path().join("vauchi-core/src").join(name);
        fs::create_dir_all(file.parent().unwrap()).unwrap();
        fs::write(file, source).unwrap();
    }
    temp
}

fn edges(report: &Report) -> BTreeSet<(String, String)> {
    report
        .references
        .iter()
        .map(|r| (r.source.clone(), r.target.clone()))
        .collect()
}

fn has_edge(root: &Path, from: &str, to: &str) {
    let report = analyze(root).unwrap();
    assert!(
        edges(&report).contains(&(format!("vauchi-core/{from}"), format!("vauchi-core/{to}"))),
        "{report:?}"
    );
}

// @internal — architecture analyzer source-input contract.
#[test]
fn relative_and_root_reexport_imports_reach_the_owning_module() {
    let root = fixture(&[
        (
            "lib.rs",
            "pub mod api; pub mod storage; pub use storage::Storage;",
        ),
        (
            "api.rs",
            "use crate::Storage; use super::storage::Storage as Other;",
        ),
        ("storage.rs", "pub struct Storage;"),
    ]);
    let report = analyze(root.path()).unwrap();
    let paths: Vec<_> = report
        .references
        .iter()
        .filter(|r| r.source == "vauchi-core/api" && r.target == "vauchi-core/storage")
        .collect();
    assert_eq!(paths.len(), 2, "{report:?}");
    assert!(paths
        .iter()
        .all(|r| r.symbol == "vauchi_core::storage::Storage"));
}

// @internal — architecture analyzer source-input contract.
#[test]
fn renamed_reexports_and_globs_resolve_transitively() {
    let root = fixture(&[
        (
            "lib.rs",
            "mod api; mod bridge; mod storage; pub use bridge::*;",
        ),
        ("api.rs", "use crate::Database;"),
        ("bridge.rs", "pub use crate::storage::Storage as Database;"),
        ("storage.rs", "pub struct Storage;"),
    ]);
    has_edge(root.path(), "api", "storage");
}

// @internal — architecture analyzer source-input contract.
#[test]
fn nontrailing_test_modules_do_not_hide_production_code() {
    let root = fixture(&[
        ("lib.rs", "mod api; mod storage;"),
        (
            "api.rs",
            "#[cfg(test)] mod tests { use crate::storage::Storage; } pub fn later(_: crate::storage::Storage) {}",
        ),
        ("storage.rs", "pub struct Storage;"),
    ]);
    let report = analyze(root.path()).unwrap();
    let paths: Vec<_> = report
        .references
        .iter()
        .filter(|r| r.source == "vauchi-core/api")
        .collect();
    assert_eq!(paths.len(), 1, "{report:?}");
    assert!(paths[0].owner.ends_with("later"));
}

// @internal — architecture analyzer source-input contract.
#[test]
fn inline_modules_and_path_attributes_use_logical_ownership() {
    let root = fixture(&[
        (
            "lib.rs",
            "#[path = \"data.rs\"] mod storage; mod api { mod nested { use super::super::storage::Storage; } }",
        ),
        ("data.rs", "pub struct Storage;"),
    ]);
    has_edge(root.path(), "api", "storage");
}

// @internal — architecture analyzer source-input contract.
#[test]
fn explicit_macro_paths_count_but_comments_and_strings_do_not() {
    let root = fixture(&[
        ("lib.rs", "mod api; mod storage;"),
        (
            "api.rs",
            "// crate::storage::Storage\nconst TEXT: &str = \"crate::storage::Storage\"; generate!(crate::storage::Storage);",
        ),
        ("storage.rs", "pub struct Storage;"),
    ]);
    let report = analyze(root.path()).unwrap();
    assert_eq!(
        report
            .references
            .iter()
            .filter(|r| r.source == "vauchi-core/api")
            .count(),
        1
    );
    has_edge(root.path(), "api", "storage");
}

// @internal — architecture analyzer source-input contract.
#[test]
fn production_feature_branches_are_checked_and_test_only_items_are_not() {
    let root = fixture(&[
        ("lib.rs", "mod api; mod storage;"),
        (
            "api.rs",
            "#[cfg(feature = \"network\")] fn enabled(_: crate::storage::Storage) {} #[cfg(test)] fn only_test(_: crate::storage::Storage) {}",
        ),
        ("storage.rs", "pub struct Storage;"),
    ]);
    let report = analyze(root.path()).unwrap();
    assert_eq!(
        report
            .references
            .iter()
            .filter(|r| r.source == "vauchi-core/api")
            .count(),
        1
    );
}

// @internal — fail closed on incomplete or invalid input.
#[test]
fn malformed_missing_and_escaping_modules_are_errors() {
    for source in [
        "mod absent;",
        "fn broken(",
        "#[path = \"../../outside.rs\"] mod escape;",
    ] {
        let root = fixture(&[("lib.rs", source)]);
        fs::write(root.path().join("outside.rs"), "pub struct Outside;").unwrap();
        assert!(analyze(root.path()).is_err(), "accepted {source}");
    }
    assert!(analyze(TempDir::new().unwrap().path()).is_err());
}

// @internal — generated source is parsed, never treated as an empty include.
#[test]
fn generated_include_requires_output_and_keeps_dependency_ownership() {
    let root = fixture(&[
        ("lib.rs", "mod api; mod storage;"),
        (
            "api.rs",
            "include!(concat!(env!(\"OUT_DIR\"), \"/data.rs\"));",
        ),
        ("storage.rs", "pub struct Storage;"),
    ]);
    assert!(analyze(root.path()).is_err());
    let generated = TempDir::new().unwrap();
    fs::write(
        generated.path().join("data.rs"),
        "pub fn generated(_: crate::storage::Storage) {}",
    )
    .unwrap();
    let report = analyze_with_generated(root.path(), Some(generated.path())).unwrap();
    assert!(report
        .references
        .iter()
        .any(|r| r.source == "vauchi-core/api" && r.target == "vauchi-core/storage"));
    fs::write(generated.path().join("data.rs"), "mod missing;").unwrap();
    assert!(analyze_with_generated(root.path(), Some(generated.path())).is_err());
}

// @internal — resolve identifiers produced by a local single-identifier macro.
#[test]
fn local_identifier_macro_keeps_generated_type_ownership() {
    let root = fixture(&[
        ("lib.rs", "mod api; mod storage;"),
        ("api.rs", "use crate::storage::Generated;"),
        (
            "storage.rs",
            "macro_rules! make { ($name:ident) => { pub struct $name; }; } make!(Generated);",
        ),
    ]);
    has_edge(root.path(), "api", "storage");
}
