// SPDX-FileCopyrightText: 2026 Mattia Egloff <mattia.egloff@pm.me>
// SPDX-License-Identifier: GPL-3.0-or-later

use serde_json::json;
use std::fs;
use tempfile::TempDir;
use vauchi_architecture_check::{
    analyze_with_generated,
    policy::{self, Baseline, Policy},
};

fn fixture(import: &str, dependencies: serde_json::Value) -> TempDir {
    let root = TempDir::new().unwrap();
    let mut packages = vec![];
    for name in ["vauchi-core", "vauchi-hardware"] {
        let dir = root.path().join(name);
        fs::create_dir_all(dir.join("src")).unwrap();
        fs::write(dir.join("Cargo.toml"), "").unwrap();
        fs::write(dir.join("src/lib.rs"), if name == "vauchi-core" {
            "pub mod platform { pub struct Event; } pub mod identity { pub struct Identity; } pub use identity::Identity;"
        } else { import }).unwrap();
        packages.push(json!({"id":name,"name":name,"manifest_path":dir.join("Cargo.toml"),
            "targets":[{"name":name.replace('-', "_"),"kind":["lib"],"src_path":dir.join("src/lib.rs")}],
            "dependencies":if name=="vauchi-hardware" {dependencies.clone()} else {json!([])}}));
    }
    fs::write(
        root.path().join("cargo-metadata.json"),
        serde_json::to_vec(&json!({
            "packages":packages,"workspace_members":["vauchi-core","vauchi-hardware"]
        }))
        .unwrap(),
    )
    .unwrap();
    root
}

fn policy() -> Policy {
    serde_json::from_value(json!({
        "schema_version":1,"crates":{"vauchi-core":1,"vauchi-hardware":2},
        "layers":{"vauchi-core/lib":5,"vauchi-core/platform":2,"vauchi-core/identity":1,"vauchi-hardware/lib":1},
        "compatibility_modules":[],
        "external_modules":{"vauchi-hardware":["vauchi-core/platform"]},
        "dependencies":{"vauchi-hardware":["vauchi-core","tokio"]}
    })).unwrap()
}

fn check(root: &TempDir) -> Result<(), Vec<String>> {
    let report = analyze_with_generated(root.path(), Some(root.path())).unwrap();
    policy::check(
        &report,
        &policy(),
        &Baseline {
            schema_version: 1,
            exceptions: Default::default(),
            apis: Default::default(),
        },
    )
}

// @internal — a lower-level domain dependency is still forbidden to hardware.
#[test]
fn adapter_can_import_events_but_not_domain_even_via_reexports_and_aliases() {
    let deps = json!([{"name":"vauchi-core","rename":"boundary","kind":null}]);
    let valid = fixture("use boundary::platform::Event;", deps.clone());
    assert_eq!(check(&valid), Ok(()));
    for import in [
        "use boundary::identity::Identity;",
        "use boundary::Identity;",
    ] {
        let invalid = fixture(import, deps.clone());
        assert!(check(&invalid).unwrap_err().join("\n").contains("identity"));
    }
}

// @internal — inactive, renamed, target-specific and build GUI dependencies cannot hide.
#[test]
fn manifest_dependency_gate_uses_package_identity_before_feature_selection() {
    for kind in [json!(null), json!("build")] {
        let root = fixture(
            "",
            json!([{
                "name":"gtk4","rename":"native","kind":kind,"optional":true,"target":"cfg(target_os = \"linux\")"
            }]),
        );
        assert!(check(&root).unwrap_err().join("\n").contains("gtk4"));
    }
    let root = fixture("", json!([{"name":"gtk4","rename":null,"kind":"dev"}]));
    assert_eq!(check(&root), Ok(()));
}

// @internal — approving a dependency once must not permit later widening or removal of the guard.
#[test]
fn adapter_policy_can_only_tighten() {
    let before = policy();
    for field in ["dependencies", "external_modules"] {
        let mut widened = serde_json::to_value(&before).unwrap();
        widened[field]["vauchi-hardware"]
            .as_array_mut()
            .unwrap()
            .push(json!(if field == "dependencies" {
                "gtk4"
            } else {
                "vauchi-core/identity"
            }));
        let after: Policy = serde_json::from_value(widened).unwrap();
        assert!(policy::validate_policy_tightening(&before, &after).is_err());
        let mut removed = serde_json::to_value(&before).unwrap();
        removed[field] = json!({});
        let after: Policy = serde_json::from_value(removed).unwrap();
        assert!(policy::validate_policy_tightening(&before, &after).is_err());
    }
}

// @internal — an absent metadata inventory cannot stand in for an empty dependency set.
#[test]
fn adapter_policy_requires_dependency_evidence() {
    let root = fixture("", json!([]));
    let report = analyze_with_generated(root.path(), Some(root.path())).unwrap();
    let mut value = serde_json::to_value(report).unwrap();
    value["dependencies"] = json!({});
    let report = serde_json::from_value(value).unwrap();
    assert!(policy::violations(&report, &policy())
        .unwrap_err()
        .contains("dependencies"));
}

// @internal — library-only analysis must not silently authorize an unscanned production target.
#[test]
fn extra_production_targets_cannot_escape_the_adapter_boundary() {
    for kind in ["bin", "custom-build", "example"] {
        let root = fixture(
            "",
            json!([{"name":"vauchi-core","rename":null,"kind":null}]),
        );
        let source = root.path().join("vauchi-hardware/src/extra.rs");
        fs::write(&source, "use vauchi_core::identity::Identity; fn main() {}").unwrap();
        let path = root.path().join("cargo-metadata.json");
        let mut metadata: serde_json::Value =
            serde_json::from_slice(&fs::read(&path).unwrap()).unwrap();
        metadata["packages"][1]["targets"]
            .as_array_mut()
            .unwrap()
            .push(json!({
                "name":"extra","kind":[kind],"src_path":source
            }));
        fs::write(path, serde_json::to_vec(&metadata).unwrap()).unwrap();
        assert!(check(&root).unwrap_err().join("\n").contains("unscanned"));
    }
}

fn widened(added: &[&str], records: serde_json::Value) -> Policy {
    let mut after = serde_json::to_value(policy()).unwrap();
    for entry in added {
        after["dependencies"]["vauchi-hardware"]
            .as_array_mut()
            .unwrap()
            .push(json!(entry));
    }
    after["ratified_widenings"] = records;
    serde_json::from_value(after).unwrap()
}

fn record(added: &[&str], issue: &str, reason: &str) -> serde_json::Value {
    json!({"policy":"dependencies","name":"vauchi-hardware","added":added,"issue":issue,"reason":reason})
}

// @internal — an owner-ratified native dependency lands only with its issue and reason in the same change.
#[test]
fn a_widening_needs_a_new_record_naming_every_added_entry_with_issue_and_reason() {
    let before = policy();
    let ratified = widened(
        &["zbus", "uuid"],
        json!([record(
            &["zbus", "uuid"],
            "private#770",
            "BlueZ D-Bus discovery"
        )]),
    );
    assert_eq!(
        policy::validate_policy_tightening(&before, &ratified),
        Ok(())
    );

    let partial = widened(
        &["zbus", "gtk4"],
        json!([record(&["zbus"], "private#770", "BlueZ D-Bus discovery")]),
    );
    let error = policy::validate_policy_tightening(&before, &partial).unwrap_err();
    assert!(error.contains("gtk4") && !error.contains("zbus"), "{error}");

    for (issue, reason) in [("", "BlueZ D-Bus discovery"), ("private#770", " ")] {
        let unexplained = widened(&["zbus"], json!([record(&["zbus"], issue, reason)]));
        let error = policy::validate_policy_tightening(&before, &unexplained).unwrap_err();
        assert!(error.contains("issue and reason"), "{error}");
    }
}

// @internal — a record already on main cannot authorize a later widening, nor any removal.
#[test]
fn an_existing_record_authorizes_nothing_new_and_no_record_permits_removal() {
    let records = json!([record(&["zbus"], "private#770", "BlueZ D-Bus discovery")]);
    let mut before = serde_json::to_value(policy()).unwrap();
    before["ratified_widenings"] = records.clone();
    let before: Policy = serde_json::from_value(before).unwrap();
    let error = policy::validate_policy_tightening(&before, &widened(&["zbus"], records.clone()))
        .unwrap_err();
    assert!(error.contains("zbus"), "{error}");

    let mut removed = serde_json::to_value(widened(&[], records)).unwrap();
    removed["dependencies"] = json!({});
    let removed: Policy = serde_json::from_value(removed).unwrap();
    assert!(policy::validate_policy_tightening(&policy(), &removed).is_err());
}

fn without_hardware(value: &mut serde_json::Value, fields: &[&str]) {
    for field in fields {
        match field {
            &"crates" | &"external_modules" | &"dependencies" => {
                value[field]
                    .as_object_mut()
                    .unwrap()
                    .remove("vauchi-hardware");
            }
            &"layers" => value["layers"]
                .as_object_mut()
                .unwrap()
                .retain(|k, _| !k.starts_with("vauchi-hardware/")),
            &"acyclic_crates" => value["acyclic_crates"]
                .as_array_mut()
                .unwrap()
                .retain(|c| c != "vauchi-hardware"),
            other => panic!("unknown field {other}"),
        }
    }
}

// @internal — a crate that left the workspace (ADR-077: vauchi-hardware to
// linux-hw) retires its policy in one change; nothing of it may linger.
#[test]
fn retiring_a_crate_removes_every_entry_at_once() {
    let before = policy();
    let mut retired = serde_json::to_value(&before).unwrap();
    without_hardware(
        &mut retired,
        &[
            "crates",
            "layers",
            "external_modules",
            "dependencies",
            "acyclic_crates",
        ],
    );
    let after: Policy = serde_json::from_value(retired).unwrap();
    assert_eq!(policy::validate_policy_tightening(&before, &after), Ok(()));
}

// @internal — dropping a crate from `crates` while its layers or guards stay
// is neither a retirement nor a tightening.
#[test]
fn retiring_a_crate_but_keeping_an_entry_is_refused() {
    let before = policy();
    for keep in [
        "layers",
        "external_modules",
        "dependencies",
        "acyclic_crates",
    ] {
        let mut partial = serde_json::to_value(&before).unwrap();
        let fields: Vec<&str> = [
            "crates",
            "layers",
            "external_modules",
            "dependencies",
            "acyclic_crates",
        ]
        .into_iter()
        .filter(|f| *f != keep)
        .collect();
        without_hardware(&mut partial, &fields);
        let after: Policy = serde_json::from_value(partial).unwrap();
        let err = policy::validate_policy_tightening(&before, &after).unwrap_err();
        assert!(err.contains("retire"), "{keep}: {err}");
    }
}
