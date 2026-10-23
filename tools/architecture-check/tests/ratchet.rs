// SPDX-FileCopyrightText: 2026 Mattia Egloff <mattia.egloff@pm.me>
// SPDX-License-Identifier: GPL-3.0-or-later

use vauchi_architecture_check::{
    policy::{self, Baseline, Policy},
    Report,
};

// @internal — removing a violation requires retiring its allowance in the same change.
#[test]
fn unused_allowances_cannot_leave_room_for_reintroduction() {
    let p: Policy = serde_json::from_str(r#"{"schema_version":1,"crates":{"vauchi-core":1},"layers":{"vauchi-core/lib":5},"compatibility_modules":[]}"#).unwrap();
    let r = Report {
        modules: ["vauchi-core/lib".into()].into(),
        ..Report::default()
    };
    let mut baseline: Baseline = serde_json::from_str(r##"{"schema_version":1,"exceptions":{"old":{"count":1,"issue":"#765","reason":"migration"}},"apis":["DomainCommand::Old"]}"##).unwrap();
    let errors = policy::check(&r, &p, &baseline).unwrap_err();
    assert!(errors.iter().any(|e| e.contains("old")));
    assert!(errors.iter().any(|e| e.contains("DomainCommand::Old")));
    baseline.exceptions.clear();
    baseline.apis.clear();
    assert_eq!(policy::check(&r, &p, &baseline), Ok(()));
}

// @internal — changing layer numbers must not authorize an existing forbidden edge.
#[test]
fn existing_layer_policy_cannot_be_weakened() {
    let before: Policy = serde_json::from_str(r#"{"schema_version":1,"crates":{"vauchi-core":1},"layers":{"vauchi-core/lib":5,"vauchi-core/domain":1},"compatibility_modules":["vauchi-core/types"]}"#).unwrap();
    let mut after: Policy = serde_json::from_value(serde_json::to_value(&before).unwrap()).unwrap();
    assert_eq!(policy::validate_policy_tightening(&before, &after), Ok(()));
    after.layers.insert("vauchi-core/domain".into(), 5);
    assert!(policy::validate_policy_tightening(&before, &after)
        .unwrap_err()
        .contains("domain"));
    after.layers = before.layers.clone();
    after.compatibility_modules.clear();
    assert!(policy::validate_policy_tightening(&before, &after)
        .unwrap_err()
        .contains("compatibility"));
}
