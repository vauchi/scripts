// SPDX-FileCopyrightText: 2026 Mattia Egloff <mattia.egloff@pm.me>
// SPDX-License-Identifier: GPL-3.0-or-later

use std::fs;
use tempfile::TempDir;
use vauchi_architecture_check::analyze;

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
