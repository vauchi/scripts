// SPDX-FileCopyrightText: 2026 Mattia Egloff <mattia.egloff@pm.me>
// SPDX-License-Identifier: GPL-3.0-or-later

use std::fs;
use tempfile::TempDir;
use vauchi_architecture_check::{
    analyze,
    policy::{self, Policy},
};

fn fixture(source: &str) -> TempDir {
    let temp = TempDir::new().unwrap();
    let src = temp.path().join("vauchi-core/src");
    fs::create_dir_all(&src).unwrap();
    fs::write(
        src.join("lib.rs"),
        "mod domain; mod values; mod types; pub use values::Value;",
    )
    .unwrap();
    fs::write(src.join("domain.rs"), source).unwrap();
    fs::write(src.join("values.rs"), "pub struct Value;").unwrap();
    fs::write(src.join("types.rs"), "pub use crate::values::Value;").unwrap();
    temp
}

// @internal — visibility paths are access control, not module dependencies.
#[test]
fn crate_visibility_does_not_depend_on_the_composition_root() {
    let root = fixture("pub(crate) struct Domain; pub(in crate) fn value() {} ");
    let report = analyze(root.path()).unwrap();
    assert!(!report
        .references
        .iter()
        .any(|r| r.source == "vauchi-core/domain"));
}

// @internal — canonical resolution must not erase compatibility-path use.
#[test]
fn compatibility_alias_is_reported_while_direct_owner_import_is_clean() {
    let p: Policy = serde_json::from_str(r#"{"schema_version":1,"crates":{"vauchi-core":1},"layers":{"vauchi-core/lib":5,"vauchi-core/domain":1,"vauchi-core/values":0,"vauchi-core/types":5},"compatibility_modules":["vauchi-core/types"]}"#).unwrap();
    let root = fixture("use crate::types as legacy; fn value(_: legacy::Value) {}");
    let report = analyze(root.path()).unwrap();
    assert!(policy::violations(&report, &p)
        .unwrap()
        .keys()
        .any(|k| k.contains("::value")));
    fs::write(
        root.path().join("vauchi-core/src/domain.rs"),
        "use crate::values::Value; fn value(_: Value) {}",
    )
    .unwrap();
    assert!(policy::violations(&analyze(root.path()).unwrap(), &p)
        .unwrap()
        .is_empty());
}

// @internal — public aliases remain supported for downstream crates.
#[test]
fn public_compatibility_alias_remains_available_to_consumers() {
    let root = fixture("pub struct Domain;");
    let source = root.path().join("vauchi-platform/src");
    fs::create_dir_all(&source).unwrap();
    fs::write(source.join("lib.rs"), "mod shell;").unwrap();
    fs::write(source.join("shell.rs"), "use vauchi_core::types::Value;").unwrap();
    let p: Policy = serde_json::from_str(r#"{"schema_version":1,"crates":{"vauchi-core":1,"vauchi-platform":3},"layers":{"vauchi-core/lib":5,"vauchi-core/domain":1,"vauchi-core/values":0,"vauchi-core/types":5,"vauchi-platform/lib":0,"vauchi-platform/shell":0},"compatibility_modules":["vauchi-core/types"]}"#).unwrap();
    assert_eq!(
        policy::violations(&analyze(root.path()).unwrap(), &p).unwrap(),
        Default::default()
    );
}
