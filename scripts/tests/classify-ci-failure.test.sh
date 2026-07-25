#!/usr/bin/env bash
# SPDX-FileCopyrightText: 2026 Mattia Egloff <mattia.egloff@pm.me>
# SPDX-License-Identifier: GPL-3.0-or-later
#
# Test runner for `scripts/scripts/classify-ci-failure.sh`.
#
# The classifier turns a CI job trace into a deterministic {category, fix,
# escalate} verdict by regex, so `/ci-fix` spends NO model tokens
# re-classifying the common failures — the model is reserved for the
# actual fix and for the unknown tail (escalate=true). This test pins the
# signature→category mapping (the documented ci-fix table) and the
# unknown-escalation contract.
#
# Run: bash scripts/scripts/tests/classify-ci-failure.test.sh

set -euo pipefail

set -uo pipefail

DIR="$(cd "$(dirname "$0")/.." && pwd)"
SCRIPT="$DIR/classify-ci-failure.sh"

if [[ ! -x "$SCRIPT" ]]; then
    echo "FATAL: $SCRIPT not executable (not implemented yet — RED)" >&2
    exit 1
fi

PASS=0
FAIL=0

# classify <trace-text> -> prints JSON verdict
classify() { printf '%s\n' "$1" | bash "$SCRIPT"; }

expect_category() {
    local name="$1" trace="$2" want="$3"
    local got
    got=$(classify "$trace" | jq -r '.category' 2>/dev/null)
    if [[ "$got" == "$want" ]]; then
        printf '  PASS  %s\n' "$name"; PASS=$((PASS + 1))
    else
        printf '  FAIL  %s\n    want category=%s, got=%s\n' "$name" "$want" "$got"
        FAIL=$((FAIL + 1))
    fi
}

expect_escalate() {
    local name="$1" trace="$2" want="$3"
    local got
    got=$(classify "$trace" | jq -r '.escalate' 2>/dev/null)
    if [[ "$got" == "$want" ]]; then
        printf '  PASS  %s\n' "$name"; PASS=$((PASS + 1))
    else
        printf '  FAIL  %s\n    want escalate=%s, got=%s\n' "$name" "$want" "$got"
        FAIL=$((FAIL + 1))
    fi
}

expect_fix() {
    local name="$1" trace="$2" want="$3"
    local got
    got=$(classify "$trace" | jq -r '.fix' 2>/dev/null)
    if [[ "$got" == "$want" ]]; then
        printf '  PASS  %s\n' "$name"; PASS=$((PASS + 1))
    else
        printf '  FAIL  %s\n    want fix=%s, got=%s\n' "$name" "$want" "$got"
        FAIL=$((FAIL + 1))
    fi
}

expect_category "C FFI cross-compile" \
    "  = note: fatal error: 'openssl/ssl.h' file not found" "c-ffi-cross"
expect_category "dependency resolution" \
    "error: failed to select a version for \`libc\`" "dep-resolution"
expect_category "missing tool (bash)" \
    "/bin/sh: cargo-nextest: command not found" "missing-tool"
expect_category "missing tool (busybox)" \
    "sh: mold: not found" "missing-tool"
expect_category "timeout" \
    "ERROR: Job exceeded maximum timeout of 3600 seconds" "timeout"
expect_category "branch protection" \
    "remote: GitLab: pre-receive hook declined" "branch-protection"
expect_category "rust compile error" \
    "error[E0433]: failed to resolve: use of undeclared crate" "compile-error"
expect_category "Swift missing argument compile error" \
    "BleExchangeService.swift:209:80: error: missing argument for parameter 'direction' in call" \
    "compile-error"
expect_category "Kotlin missing argument compile error" \
    "CoreAppViewModel.kt:397:52 No value passed for parameter 'direction'." \
    "compile-error"
expect_category "test failure" \
    "test result: FAILED. 3 passed; 1 failed" "test-failure"
expect_category "hook self-test suite failure" \
    "FAILED: 1 hook self-test suite(s) red." "test-failure"
expect_category "private workspace discovery failure" \
    "ValueError: expected _private git common directory, got /builds/vauchi/private" \
    "test-failure"
expect_category "clippy/lint" \
    "error: this \`if\` has identical blocks (clippy::if_same_then_else)" "lint"
expect_category "artifact gap" \
    "cp: cannot stat 'target/release/libvauchi.a': No such file or directory" "artifact-gap"
expect_category "remote scripts ref artifact gap" \
    'curl: (22) The requested URL returned error: 404' "artifact-gap"
expect_category "duplicate package publish" \
    'curl: (22) The requested URL returned error: 400' "duplicate-publish"
expect_escalate "duplicate package publish does NOT escalate" \
    'curl: (22) The requested URL returned error: 400' "false"
expect_fix "duplicate package publish forbids registry deletion" \
    'curl: (22) The requested URL returned error: 400' \
    "Registry rejected the upload — usually a rerun at an already-published version (triggered/scheduled pipeline missing a source guard). Exclude that source from the publish job; never delete the published package to let a rerun pass."
expect_category "semver API compatibility" \
    '--- failure method_parameter_count_changed: pub method parameter count changed ---' \
    "semver-api-compatibility"
expect_escalate "semver API compatibility does NOT escalate" \
    'Summary semver requires new major version: 1 major and 0 minor checks failed' \
    "false"
expect_fix "semver API compatibility preserves the gate" \
    'Summary semver requires new major version: 1 major and 0 minor checks failed' \
    "Restore the public API compatibility or intentionally bump the major version; never suppress the semver lint."
expect_category "YAML syntax" \
    "yaml.scanner.ScannerError: could not find expected ':'" \
    "yaml-syntax"
expect_escalate "YAML syntax does NOT escalate" \
    "could not find expected ':'" "false"
expect_fix "YAML syntax preserves the lint gate" \
    "could not find expected ':'" \
    "Fix the invalid YAML indentation or syntax, then rerun the CI lint; never suppress the lint."
expect_category "required CI template variable" \
    "/usr/bin/bash: line 222: FETCH_SCRIPT_PATH: FETCH_SCRIPT_PATH must be set" \
    "template-contract"
expect_escalate "required CI template variable does NOT escalate" \
    "FETCH_SCRIPT_PATH: FETCH_SCRIPT_PATH must be set" "false"
expect_fix "required CI template variable preserves execution order" \
    "FETCH_SCRIPT_PATH: FETCH_SCRIPT_PATH must be set" \
    "Bind the required CI-template variable before the shared step; flatten nested !reference chains if ordering was lost."
expect_category "minimum just syntax compatibility" \
    'error: Recipe `create` has both shebang line and `[script]` attribute' \
    "just-syntax"
expect_escalate "minimum just syntax compatibility does NOT escalate" \
    'has both shebang line and `[script]` attribute' "false"
expect_fix "minimum just syntax chooses one interpreter contract" \
    'has both shebang line and `[script]` attribute' \
    "Use a shebang recipe or the [script] attribute, not both; verify with the minimum supported just version."

# Unknown → escalate to the model
expect_category "unknown signature" \
    "some totally novel error nobody has a rule for yet" "unknown"
expect_escalate "unknown escalates"   "novel unseen failure text" "true"
expect_escalate "known does NOT escalate" \
    "error: failed to select a version for \`libc\`" "false"

# Specificity: a compile error line that also contains the word "failed"
# must classify as compile-error, not test-failure (order matters).
expect_category "compile-error beats generic failed" \
    "error[E0599]: no method named foo; note: build failed" "compile-error"

echo ""
if [[ "$FAIL" -eq 0 ]]; then
    printf 'classify-ci-failure.test: %d passed, 0 failed\n' "$PASS"; exit 0
else
    printf 'classify-ci-failure.test: %d passed, %d FAILED\n' "$PASS" "$FAIL"; exit 1
fi
