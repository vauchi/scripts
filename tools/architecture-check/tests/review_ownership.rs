// SPDX-FileCopyrightText: 2026 Mattia Egloff <mattia.egloff@pm.me>
// SPDX-License-Identifier: GPL-3.0-or-later

use std::fs;
use tempfile::TempDir;
use vauchi_architecture_check::analyze;

fn fixture(lib: &str, domain: &str) -> TempDir {
    let root = TempDir::new().unwrap();
    let src = root.path().join("vauchi-core/src");
    fs::create_dir_all(&src).unwrap();
    fs::write(src.join("lib.rs"), lib).unwrap();
    fs::write(src.join("domain.rs"), domain).unwrap();
    fs::write(src.join("storage.rs"), "pub struct S;").unwrap();
    root
}

// @internal — inherited local macros are evaluated at the caller's owning layer.
#[test]
fn ancestor_macro_retains_calling_module() {
    let r = fixture(
        "macro_rules! make { () => {pub fn generated(_: crate::storage::S) {}}; } mod domain; mod storage;",
        "make!();",
    );
    assert!(analyze(r.path())
        .unwrap()
        .references
        .iter()
        .any(|r| r.source == "vauchi-core/domain" && r.target == "vauchi-core/storage"));
}

// @internal — self aliases declared at crate root remain visible in child modules.
#[test]
fn crate_self_alias_retains_internal_dependency() {
    let r = fixture(
        "extern crate self as local; mod domain; mod storage;",
        "fn f(_: local::storage::S) {}",
    );
    assert!(analyze(r.path())
        .unwrap()
        .references
        .iter()
        .any(|r| r.source == "vauchi-core/domain" && r.target == "vauchi-core/storage"));
}

// @internal — unsupported function-local source files must fail, not disappear.
#[test]
fn local_external_module_cannot_pass_unvisited() {
    let r = fixture(
        "mod domain; mod storage;",
        "fn outer() { #[path = \"inside.rs\"] mod nested; }",
    );
    fs::write(
        r.path().join("vauchi-core/src/inside.rs"),
        "fn f(_: crate::storage::S) {}",
    )
    .unwrap();
    assert!(analyze(r.path()).unwrap_err().contains("local module"));
}

// @internal — a Cargo manifest cannot redirect compilation away from scanned roots.
#[test]
fn manifested_source_requires_verified_cargo_metadata() {
    let r = fixture("mod domain; mod storage;", "pub struct D;");
    fs::write(
        r.path().join("vauchi-core/Cargo.toml"),
        "[package]\nname=\"vauchi-core\"\nversion=\"0.1.0\"\n[lib]\npath=\"src/entry.rs\"\n",
    )
    .unwrap();
    fs::write(
        r.path().join("vauchi-core/src/entry.rs"),
        "mod domain; mod storage;",
    )
    .unwrap();
    assert!(analyze(r.path()).unwrap_err().contains("metadata"));
}

// @internal — an allowance cannot transfer between trait implementations of a type.
#[test]
fn trait_implementation_is_part_of_caller_identity() {
    let r = fixture(
        "mod domain; mod storage;",
        "trait A {fn f();} trait B {fn f();} struct D; impl A for D {fn f(){let _=crate::storage::S;}} impl B for D {fn f(){}}",
    );
    let before = analyze(r.path()).unwrap();
    fs::write(r.path().join("vauchi-core/src/domain.rs"), "trait A {fn f();} trait B {fn f();} struct D; impl A for D {fn f(){}} impl B for D {fn f(){let _=crate::storage::S;}}").unwrap();
    let after = analyze(r.path()).unwrap();
    assert_ne!(
        before.references.iter().next().unwrap().owner,
        after.references.iter().next().unwrap().owner
    );
}

// @internal — exported callback methods are API entries, not only the trait name.
#[test]
fn exported_trait_methods_are_individually_inventoried() {
    let r = fixture(
        "#[uniffi::export(callback_interface)] pub trait Callback {fn existing(&self); fn new_domain_action(&self);}",
        "",
    );
    let apis = analyze(r.path()).unwrap().apis;
    assert!(apis
        .iter()
        .any(|a| a.ends_with("Callback::new_domain_action")));
    assert!(apis.iter().any(|a| a.ends_with("Callback::existing")));
}

// @internal — test-only associated items do not add production dependencies.
#[test]
fn associated_test_items_are_excluded() {
    let r = fixture(
        "mod domain; mod storage;",
        "trait T { #[cfg(test)] const BAD: crate::storage::S; } struct D; impl D {#[cfg(test)] const BAD: crate::storage::S=crate::storage::S;}",
    );
    assert!(!analyze(r.path())
        .unwrap()
        .references
        .iter()
        .any(|r| r.source == "vauchi-core/domain"));
}
