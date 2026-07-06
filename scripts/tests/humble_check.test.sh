#!/usr/bin/env bash
# SPDX-FileCopyrightText: 2026 Mattia Egloff <mattia.egloff@pm.me>
#
# SPDX-License-Identifier: GPL-3.0-or-later

# Sentinel regression suite for humble_check.py — the cross-language
# Humble UI ratchet (ADR-043 Amendment 6).
#
# Builds synthetic frontend trees, plants known sentinel lines, runs the
# real script, and asserts the ratchet counts violations, respects
# TODO(HUMBLE) / HUMBLE-EXCEPTION markers, and fails --check when a count
# rises above the baseline.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
SCRIPT="$SCRIPT_DIR/../humble_check.py"
CONFIG="$SCRIPT_DIR/../humble_check_rules.json"

pass=0
fail=0

assert_eq() {
    name="$1"; want="$2"; got="$3"
    if [ "$want" = "$got" ]; then
        printf '  PASS %s\n' "$name"
        pass=$((pass + 1))
    else
        printf '  FAIL %s\n    want: %s\n    got:  %s\n' "$name" "$want" "$got" >&2
        fail=$((fail + 1))
    fi
}

# extract_counter <json> <rule>
extract_counter() {
    printf '%s' "$1" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d['totals'].get('$2',0))"
}

# test_empty_workspace — no source → zero counts and valid JSON
test_empty_workspace() {
    root=$(mktemp -d)
    out=$(python3 "$SCRIPT" --repo ios --workspace-root "$root" --config "$CONFIG"); rc=$?
    assert_eq "empty: exit 0" 0 "$rc"
    assert_eq "empty: ios action_id_minting == 0" "0" "$(extract_counter "$out" action_id_minting)"
    assert_eq "empty: ios domain_screen_id_branch == 0" "0" "$(extract_counter "$out" domain_screen_id_branch)"
    rm -rf "$root"
}

# test_counts_violations — planted action-id minting and screen-id branch
test_counts_violations() {
    root=$(mktemp -d)
    dir="$root/ios/Vauchi/CoreUI"
    mkdir -p "$dir"
    cat >"$dir/BadView.swift" <<'SW'
class BadView {
    func makeEditAction(for component: Component) -> String {
        return "\(component.id):edit"
    }
    func route(screenId: String) {
        if screenId == "multi_stage_exchange" { startTimer() }
    }
}
SW
    out=$(python3 "$SCRIPT" --repo ios --workspace-root "$root" --config "$CONFIG")
    assert_eq "violations: action_id_minting == 1" "1" "$(extract_counter "$out" action_id_minting)"
    assert_eq "violations: domain_screen_id_branch == 1" "1" "$(extract_counter "$out" domain_screen_id_branch)"
    rm -rf "$root"
}

# test_todo_suppresses — TODO(HUMBLE) within lookback window suppresses
test_todo_suppresses() {
    root=$(mktemp -d)
    dir="$root/ios/Vauchi/CoreUI"
    mkdir -p "$dir"
    cat >"$dir/AnnotatedView.swift" <<'SW'
class AnnotatedView {
    // TODO(HUMBLE): action-id minting grandfathered until core supplies edit_action_id
    func makeEditAction(for component: Component) -> String {
        return "\(component.id):edit"
    }
}
SW
    out=$(python3 "$SCRIPT" --repo ios --workspace-root "$root" --config "$CONFIG")
    assert_eq "todo: action_id_minting == 0" "0" "$(extract_counter "$out" action_id_minting)"
    rm -rf "$root"
}

# test_exception_suppresses — HUMBLE-EXCEPTION marker suppresses
test_exception_suppresses() {
    root=$(mktemp -d)
    dir="$root/ios/Vauchi/CoreUI"
    mkdir -p "$dir"
    cat >"$dir/ExceptedView.swift" <<'SW'
class ExceptedView {
    // HUMBLE-EXCEPTION: ADR-043 Am6 — temporary bridge until core emits icon_token
    func iconForFieldType(_ type: String) -> String { "phone" }
}
SW
    out=$(python3 "$SCRIPT" --repo ios --workspace-root "$root" --config "$CONFIG")
    assert_eq "exception: field_visibility_interpretation == 0" "0" "$(extract_counter "$out" field_visibility_interpretation)"
    rm -rf "$root"
}

# test_excluded_paths — Generated/ and test trees do not count
test_excluded_paths() {
    root=$(mktemp -d)
    real="$root/ios/Vauchi/CoreUI"
    gen="$root/ios/Vauchi/Generated"
    tests="$root/ios/VauchiTests"
    mkdir -p "$real" "$gen" "$tests"
    cat >"$real/RealView.swift" <<'SW'
class RealView {
    func route(screenId: String) {
        if screenId == "multi_stage_exchange" { startTimer() }
    }
}
SW
    cat >"$gen/GenView.swift" <<'SW'
class GenView {
    func route(screenId: String) {
        if screenId == "multi_stage_exchange" { startTimer() }
    }
}
SW
    cat >"$tests/NavTests.swift" <<'SW'
class NavTests {
    func route(screenId: String) {
        if screenId == "multi_stage_exchange" { startTimer() }
    }
}
SW
    out=$(python3 "$SCRIPT" --repo ios --workspace-root "$root" --config "$CONFIG")
    assert_eq "excluded: only real code counts == 1" "1" "$(extract_counter "$out" domain_screen_id_branch)"
    rm -rf "$root"
}

# test_check_above_baseline_fails — regression exits 1
test_check_above_baseline_fails() {
    root=$(mktemp -d)
    dir="$root/ios/Vauchi/CoreUI"
    mkdir -p "$dir"
    cat >"$dir/BadView.swift" <<'SW'
class BadView {
    func route(screenId: String) {
        if screenId == "multi_stage_exchange" { startTimer() }
    }
}
SW
    base="$root/baseline.json"
    cat >"$base" <<'JSON'
{
  "schema_version": 1,
  "repos": {
    "ios": {
      "domain_screen_id_branch": 0,
      "action_id_minting": 0
    }
  }
}
JSON
    set +e
    python3 "$SCRIPT" --repo ios --workspace-root "$root" --config "$CONFIG" --check "$base" >/dev/null 2>&1
    rc=$?
    set -e
    assert_eq "check: exit 1 when count exceeds baseline" "1" "$rc"
    rm -rf "$root"
}

# test_check_at_baseline_passes — no regression exits 0
test_check_at_baseline_passes() {
    root=$(mktemp -d)
    dir="$root/ios/Vauchi/CoreUI"
    mkdir -p "$dir"
    cat >"$dir/BadView.swift" <<'SW'
class BadView {
    func route(screenId: String) {
        if screenId == "multi_stage_exchange" { startTimer() }
    }
}
SW
    base="$root/baseline.json"
    cat >"$base" <<'JSON'
{
  "repos": {
    "ios": {
      "domain_screen_id_branch": 1,
      "action_id_minting": 0
    }
  }
}
JSON
    set +e
    python3 "$SCRIPT" --repo ios --workspace-root "$root" --config "$CONFIG" --check "$base" >/dev/null 2>&1
    rc=$?
    set -e
    assert_eq "check: exit 0 at baseline" "0" "$rc"
    rm -rf "$root"
}

# test_json_validity — snapshot output is valid JSON
test_json_validity() {
    root=$(mktemp -d)
    out=$(python3 "$SCRIPT" --repo ios --workspace-root "$root" --config "$CONFIG")
    if printf '%s' "$out" | python3 -m json.tool >/dev/null 2>&1; then
        printf '  PASS json: parses as JSON\n'; pass=$((pass + 1))
    else
        printf '  FAIL json: invalid JSON\n    output: %s\n' "$out" >&2
        fail=$((fail + 1))
    fi
    rm -rf "$root"
}

# test_bad_repo — unknown repo exits 2
test_bad_repo() {
    root=$(mktemp -d)
    set +e
    python3 "$SCRIPT" --repo unknown --workspace-root "$root" --config "$CONFIG" >/dev/null 2>&1
    rc=$?
    set -e
    assert_eq "bad repo: exit 2" "2" "$rc"
    rm -rf "$root"
}

# run
test_empty_workspace
test_counts_violations
test_todo_suppresses
test_exception_suppresses
test_excluded_paths
test_check_above_baseline_fails
test_check_at_baseline_passes
test_json_validity
test_bad_repo

printf '\n%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
