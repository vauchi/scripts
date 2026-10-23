// SPDX-FileCopyrightText: 2026 Mattia Egloff <mattia.egloff@pm.me>
// SPDX-License-Identifier: GPL-3.0-or-later

use vauchi_architecture_check::{
    policy::{self, Baseline, Policy},
    Reference, Report,
};

fn policy() -> Policy {
    serde_json::from_str(
        r#"{"schema_version":1,"crates":{"vauchi-core":1},
        "layers":{"vauchi-core/lib":1,"vauchi-core/a":1,
        "vauchi-core/b":1,"vauchi-core/c":1,"vauchi-core/tail":1},
        "compatibility_modules":[],"acyclic_crates":["vauchi-core"]}"#,
    )
    .unwrap()
}

fn report(edges: &[(&str, &str)]) -> Report {
    Report {
        modules: policy().layers.into_keys().collect(),
        references: edges
            .iter()
            .map(|(source, target)| Reference {
                source: format!("vauchi-core/{source}"),
                target: format!("vauchi-core/{target}"),
                file: format!("vauchi-core/src/{source}.rs"),
                owner: format!("vauchi_core::{source}::caller"),
                symbol: format!("vauchi_core::{target}::callee"),
                via: Default::default(),
                line: 1,
                column: 1,
            })
            .collect(),
        ..Report::default()
    }
}

fn baseline() -> Baseline {
    Baseline {
        schema_version: 1,
        exceptions: Default::default(),
        apis: Default::default(),
    }
}

// @internal — same-layer cycles must fail even with no upward dependencies.
#[test]
fn closing_a_cycle_fails_and_removing_its_edge_passes() {
    for mut edges in [vec![("a", "b")], vec![("a", "c"), ("c", "b")]] {
        assert_eq!(
            policy::check(&report(&edges), &policy(), &baseline()),
            Ok(())
        );
        edges.push(("b", "a"));
        let errors = policy::check(&report(&edges), &policy(), &baseline()).unwrap_err();
        assert_eq!(errors.len(), 1);
        assert!(errors[0].contains("ownership cycle"), "{errors:?}");
        assert!(errors[0].contains("vauchi-core/a"), "{errors:?}");
        assert!(errors[0].contains("vauchi-core/b"), "{errors:?}");
        edges.pop();
        assert_eq!(
            policy::check(&report(&edges), &policy(), &baseline()),
            Ok(())
        );
    }
}

// @internal — diagnostics name cycle members without blaming outgoing dependencies.
#[test]
fn reports_disconnected_cycles_without_including_tails() {
    let r = report(&[
        ("a", "b"),
        ("b", "a"),
        ("b", "tail"),
        ("c", "lib"),
        ("lib", "c"),
    ]);
    assert_eq!(
        policy::check(&r, &policy(), &baseline()).unwrap_err(),
        vec![
            "VRS06: ownership cycle: vauchi-core/a, vauchi-core/b; relocate composition to its consuming module",
            "VRS06: ownership cycle: vauchi-core/c, vauchi-core/lib; relocate composition to its consuming module",
        ]
    );
}

// @internal — enabling acyclicity is allowed, silently disabling it is not.
#[test]
fn cycle_policy_can_only_be_tightened_and_rejects_unknown_crates() {
    let enabled = policy();
    let mut disabled: Policy = serde_json::from_str(
        r#"{"schema_version":1,"crates":{"vauchi-core":1},
        "layers":{"vauchi-core/lib":1,"vauchi-core/a":1,
        "vauchi-core/b":1,"vauchi-core/c":1,"vauchi-core/tail":1},
        "compatibility_modules":[]}"#,
    )
    .unwrap();
    let r = report(&[("a", "b"), ("b", "a")]);
    assert_eq!(policy::check(&r, &disabled, &baseline()), Ok(()));
    assert_eq!(
        policy::validate_policy_tightening(&disabled, &enabled),
        Ok(())
    );
    assert!(policy::validate_policy_tightening(&enabled, &disabled)
        .unwrap_err()
        .contains("acyclic"));
    disabled.acyclic_crates.insert("missing".into());
    assert!(policy::check(&r, &disabled, &baseline())
        .unwrap_err()
        .join("\n")
        .contains("missing"));
}
