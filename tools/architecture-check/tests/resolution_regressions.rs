// SPDX-FileCopyrightText: 2026 Mattia Egloff <mattia.egloff@pm.me>
// SPDX-License-Identifier: GPL-3.0-or-later

use std::fs;
use tempfile::TempDir;
use vauchi_architecture_check::{analyze, analyze_with_generated};

fn fixture(files: &[(&str, &str)]) -> TempDir {
    let root = TempDir::new().unwrap();
    for (name, source) in files {
        let path = root.path().join(name);
        fs::create_dir_all(path.parent().unwrap()).unwrap();
        fs::write(path, source).unwrap();
    }
    root
}

// @internal — a decoy at the wrong path must not hide an inline module's edge.
#[test]
fn inline_path_uses_rust_module_directory() {
    let root = fixture(&[
        (
            "vauchi-core/src/lib.rs",
            "mod domain { #[path = \"actual.rs\"] mod nested; } mod storage;",
        ),
        ("vauchi-core/src/actual.rs", "pub struct Decoy;"),
        (
            "vauchi-core/src/domain/actual.rs",
            "use crate::storage::Storage;",
        ),
        ("vauchi-core/src/storage.rs", "pub struct Storage;"),
    ]);
    let r = analyze(root.path()).unwrap();
    assert!(r
        .references
        .iter()
        .any(|r| r.source == "vauchi-core/domain" && r.target == "vauchi-core/storage"));
    assert!(!r.files.contains("vauchi-core/src/actual.rs"));
}

// @internal — extern-crate aliases retain cross-crate dependency direction.
#[test]
fn renamed_extern_crate_is_resolved() {
    let root = fixture(&[
        (
            "vauchi-core/src/lib.rs",
            "extern crate vauchi_app as upstream; fn f(_: upstream::App) {}",
        ),
        ("vauchi-app/src/lib.rs", "pub struct App;"),
    ]);
    let r = analyze(root.path()).unwrap();
    assert!(r.references.iter().any(|r| r.source == "vauchi-core/lib"
        && r.target == "vauchi-app/lib"
        && r.symbol.ends_with("::App")));
}

// @internal — an ABI spelling change cannot evade the export ratchet.
#[test]
fn c_unwind_exports_are_counted() {
    let root = fixture(&[(
        "vauchi-cabi/src/lib.rs",
        "pub unsafe extern \"C-unwind\" fn domain_operation() {}",
    )]);
    assert!(analyze(root.path())
        .unwrap()
        .apis
        .iter()
        .any(|a| a.ends_with("::domain_operation")));
}

// @internal — conditional production exports are part of the production union.
#[test]
fn conditional_uniffi_export_is_counted() {
    let root = fixture(&[(
        "vauchi-platform/src/lib.rs",
        "#[cfg_attr(feature = \"ffi\", uniffi::export)] pub fn domain_operation() {} #[cfg_attr(test, uniffi::export)] fn test_export() {}",
    )]);
    let r = analyze(root.path()).unwrap();
    assert!(r.apis.iter().any(|a| a.ends_with("::domain_operation")));
    assert!(!r.apis.iter().any(|a| a.ends_with("::test_export")));
}

fn metadata_with_dependency(root: &TempDir, dependency: &str) -> TempDir {
    let generated = TempDir::new().unwrap();
    let lib = root.path().join("vauchi-core/src/lib.rs");
    let manifest = root.path().join("vauchi-core/Cargo.toml");
    let json = format!(
        r#"{{"workspace_members": ["core-id"], "packages": [{{"id": "core-id", "name": "vauchi-core",
            "manifest_path": "{manifest}", "targets": [{{"name": "vauchi_core", "kind": ["lib"], "src_path": "{lib}"}}],
            "dependencies": [{{"name": "{dependency}", "rename": null, "kind": null}}]}}]}}"#,
        manifest = manifest.display(),
        lib = lib.display(),
    );
    fs::write(generated.path().join("cargo-metadata.json"), json).unwrap();
    generated
}

// @internal — a glob re-export of a dependency outside the scanned crates
// (ADR-078: `pub use vauchi_contract::*`) resolves without an edge.
#[test]
fn glob_reexport_of_a_dependency_resolves_without_an_edge() {
    let root = fixture(&[
        (
            "vauchi-core/Cargo.toml",
            "[package]\nname = \"vauchi-core\"\n",
        ),
        ("vauchi-core/src/lib.rs", "pub mod platform; pub mod types;"),
        ("vauchi-core/src/platform.rs", "pub use vauchi_contract::*;"),
        (
            "vauchi-core/src/types.rs",
            "use crate::platform::Command; pub fn f(_: Command) {}",
        ),
    ]);
    let generated = metadata_with_dependency(&root, "vauchi-contract");
    let r = analyze_with_generated(root.path(), Some(generated.path())).unwrap();
    assert!(
        !r.references
            .iter()
            .any(|r| r.target.starts_with("vauchi-contract")),
        "a dependency's symbol draws no module edge: {:?}",
        r.references
    );
}

// @internal — a glob re-export of a crate that is not a dependency stays an
// unresolved internal path, so a typo cannot hide behind the dependency rule.
#[test]
fn glob_reexport_of_a_non_dependency_is_still_unresolved() {
    let root = fixture(&[
        (
            "vauchi-core/Cargo.toml",
            "[package]\nname = \"vauchi-core\"\n",
        ),
        ("vauchi-core/src/lib.rs", "pub mod platform; pub mod types;"),
        (
            "vauchi-core/src/platform.rs",
            "pub use not_a_dependency::*;",
        ),
        (
            "vauchi-core/src/types.rs",
            "use crate::platform::Command; pub fn f(_: Command) {}",
        ),
    ]);
    let generated = metadata_with_dependency(&root, "vauchi-contract");
    let err = analyze_with_generated(root.path(), Some(generated.path())).unwrap_err();
    assert!(
        err.contains("unresolved internal path crate::platform::Command"),
        "{err}"
    );
}

// @internal — a named re-export of a dependency's type (ADR-078:
// `pub use vauchi_contract::network_cost::NetworkCost`) resolves like the glob.
#[test]
fn named_reexport_of_a_dependency_resolves_without_an_edge() {
    let root = fixture(&[
        (
            "vauchi-core/Cargo.toml",
            "[package]\nname = \"vauchi-core\"\n",
        ),
        ("vauchi-core/src/lib.rs", "pub mod settings; pub mod sync;"),
        (
            "vauchi-core/src/settings.rs",
            "pub use vauchi_contract::network_cost::NetworkCost;",
        ),
        (
            "vauchi-core/src/sync.rs",
            "use crate::settings::NetworkCost; pub fn f(_: NetworkCost) {}",
        ),
    ]);
    let generated = metadata_with_dependency(&root, "vauchi-contract");
    let r = analyze_with_generated(root.path(), Some(generated.path())).unwrap();
    assert!(!r
        .references
        .iter()
        .any(|r| r.target.starts_with("vauchi-contract")));
}
