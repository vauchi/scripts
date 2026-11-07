// SPDX-FileCopyrightText: 2026 Mattia Egloff <mattia.egloff@pm.me>
// SPDX-License-Identifier: GPL-3.0-or-later

use vauchi_architecture_check::complexity::{analyze_sources, SourceFile};

fn report(source: &str) -> vauchi_architecture_check::complexity::ComplexityReport {
    analyze_sources(&[SourceFile {
        path: "fixture.rs".into(),
        source: source.into(),
    }])
}

// @internal — complexity is an advisory source-analysis contract.
#[test]
fn flat_and_nested_branches_have_equal_paths_but_different_nesting() {
    let report = report("fn flat() { if a {} if b {} } fn nested() { if a { if b {} } }");
    assert_eq!(report.files_analyzed, 1);
    assert_eq!(report.failures.len(), 0);
    let scores: Vec<_> = report
        .functions
        .iter()
        .map(|f| (f.name.as_str(), f.cyclomatic, f.max_nesting))
        .collect();
    assert_eq!(scores, [("flat", 3, 1), ("nested", 3, 2)]);
}

// @internal
#[test]
fn match_alternatives_guards_short_circuits_and_try_are_counted() {
    let report = report(
        r#"
        fn choices() { match x { A if a => (), B => (), _ => () } }
        fn boolean() { if a && b || c {} }
        fn propagation() { let x = fallible()?; }
        fn loops() { for x in xs { while ok { loop { break; } } } }
    "#,
    );
    let scores: Vec<_> = report
        .functions
        .iter()
        .map(|f| (f.name.as_str(), f.cyclomatic, f.max_nesting))
        .collect();
    assert_eq!(
        scores,
        [
            ("choices", 4, 1),
            ("boolean", 4, 1),
            ("propagation", 2, 0),
            ("loops", 4, 3)
        ]
    );
}

// @internal
#[test]
fn strings_comments_and_nested_functions_do_not_inflate_the_outer_function() {
    let report = report(
        r#"
        fn outer() {
            let text = "if match while && || ?";
            // if pretend { match bad {} }
            fn inner() { if a { if b {} } }
            let callback = || { if c {} };
        }
    "#,
    );
    let scores: Vec<_> = report
        .functions
        .iter()
        .map(|f| (f.cyclomatic, f.max_nesting))
        .collect();
    assert_eq!(scores, [(1, 0), (3, 2), (2, 1)]);
    assert_eq!(report.functions[0].name, "outer");
    assert_eq!(report.functions[1].name, "inner");
}

// @internal
#[test]
fn modern_rust_methods_and_macro_opacity_are_reported() {
    let report = report(
        r#"
        impl Example { fn check(&self) { if let Some(x) = value && x > 0 { opaque!(); } } }
        trait ExampleTrait { fn default_method() { if ready {} } }
        generated_functions!();
    "#,
    );
    assert_eq!(report.failures.len(), 0);
    assert_eq!(report.files_analyzed, 1);
    assert_eq!(report.macro_invocations, 2);
    assert_eq!(report.functions[0].name, "check");
    assert_eq!(report.functions[0].cyclomatic, 3);
    assert_eq!(report.functions[0].macro_invocations, 1);
    assert_eq!(report.functions[1].name, "default_method");
    assert_eq!(report.functions[1].line, 3);
}

// @internal
#[test]
fn invalid_rust_is_a_coverage_failure_instead_of_a_zero_score() {
    let report = report("fn incomplete(");
    assert_eq!(report.files_analyzed, 0);
    assert_eq!(report.functions.len(), 0);
    assert_eq!(report.failures.len(), 1);
    assert_eq!(report.failures[0].path, "fixture.rs");
    assert!(!report.failures[0].error.is_empty());
}
