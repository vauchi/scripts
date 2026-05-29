#!/usr/bin/env bash
# SPDX-FileCopyrightText: 2026 Mattia Egloff <mattia.egloff@pm.me>
#
# SPDX-License-Identifier: GPL-3.0-or-later

# Sentinel regression suite for audit-app-preferences.sh — the
# settings-storage S5 deprecation-window lint for the legacy
# `Vauchi::app_preferences*` surface (ADR-047 / settings-storage plan).
#
# Per CC-20 / CC-21 these tests are NON-tautological: each builds a tiny
# synthetic frontend tree, plants known sentinel lines, runs the real
# script, and asserts the gate COUNTS real method CALLS (read + write,
# snake + camel) and does NOT count the documented false-positive shapes
# (the core `fn app_preferences` definition, a path-call without a
# leading dot, and backticked prose in a comment). It also asserts the
# --check ratchet exits 1 above baseline, 0 at/below, and 2 on a missing
# baseline / bad workspace.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
SCRIPT="$SCRIPT_DIR/../audit-app-preferences.sh"

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

extract_counter() {
    printf '%s' "$1" | awk -v k="\"$2\"" '
        $1 ~ k {
            v = $0
            sub(/.*:[[:space:]]+/, "", v)
            sub(/,$/, "", v)
            print v
            exit
        }
    '
}

# ── 1. Empty workspace → all zero, exit 0 ─────────────────────────────
test_empty_workspace() {
    root=$(mktemp -d)
    out=$("$SCRIPT" "$root"); rc=$?
    assert_eq "empty: exit 0" 0 "$rc"
    assert_eq "empty: total == 0" "0" "$(extract_counter "$out" app_pref_callers_total)"
    rm -rf "$root"
}

# ── 2. Rust frontend sentinel (cli) — read + write calls count; the ──
# core `fn` definition, a path call, and a backticked comment do NOT.
test_cli_sentinel() {
    root=$(mktemp -d)
    dir="$root/cli/src"
    mkdir -p "$dir"
    cat >"$dir/settings.rs" <<'RS'
fn load(vauchi: &Vauchi) {
    let p = vauchi.app_preferences().unwrap_or_default();   // counts
    vauchi.set_app_preferences(p);                          // counts
    // false positives below must NOT count:
    // `app_preferences()` mentioned in prose
}
fn app_preferences(&self) -> Prefs { todo!() }              // definition, no dot
RS
    out=$("$SCRIPT" "$root")
    assert_eq "cli: counts 2 real calls, skips fn-def + comment" \
        "2" "$(extract_counter "$out" app_pref_callers_cli)"
    rm -rf "$root"
}

# ── 3. iOS sentinel — UniFFI camelCase calls count ────────────────────
test_ios_sentinel() {
    root=$(mktemp -d)
    dir="$root/ios/Vauchi/Services"
    mkdir -p "$dir"
    cat >"$dir/Repo.swift" <<'SW'
func load() {
    let p = vauchi.appPreferences()        // counts
    vauchi.setAppPreferences(p)            // counts
    // `appPreferences()` in a comment must NOT count
}
SW
    out=$("$SCRIPT" "$root")
    assert_eq "ios: counts 2 camelCase calls, skips comment" \
        "2" "$(extract_counter "$out" app_pref_callers_ios)"
    rm -rf "$root"
}

# ── 4. Excluded subpaths do NOT contribute ────────────────────────────
test_excluded_paths() {
    root=$(mktemp -d)
    real="$root/ios/Vauchi/Services"
    gen="$root/ios/Vauchi/Generated"
    tests="$root/ios/VauchiTests"
    mkdir -p "$real" "$gen" "$tests"
    cat >"$real/Repo.swift" <<'SW'
func load() { let p = vauchi.appPreferences() }
SW
    cat >"$gen/uniffi.swift" <<'SW'
func g() { let p = handle.appPreferences() }
SW
    cat >"$tests/RepoTests.swift" <<'SW'
func t() { let p = vauchi.appPreferences() }
SW
    out=$("$SCRIPT" "$root")
    assert_eq "excluded: only the 1 real ios call counts" \
        "1" "$(extract_counter "$out" app_pref_callers_ios)"
    rm -rf "$root"
}

# ── 5. Total = sum across repos ───────────────────────────────────────
test_total_sums() {
    root=$(mktemp -d)
    c="$root/cli/src"; i="$root/ios/Vauchi/Services"
    mkdir -p "$c" "$i"
    # The lint counts caller LINES (like its sibling detectors), so real
    # one-call-per-line code: 2 cli lines + 1 ios line = 3.
    cat >"$c/s.rs" <<'RS'
fn w(v: &Vauchi) {
    v.app_preferences();
    v.set_app_preferences(p);
}
RS
    cat >"$i/r.swift" <<'SW'
func r() { vauchi.appPreferences() }
SW
    out=$("$SCRIPT" "$root")
    assert_eq "total: 2 cli + 1 ios == 3" \
        "3" "$(extract_counter "$out" app_pref_callers_total)"
    rm -rf "$root"
}

# ── 6. --check ratchet: exits nonzero ABOVE baseline ──────────────────
test_check_above_baseline_fails() {
    root=$(mktemp -d)
    c="$root/cli/src"; mkdir -p "$c"
    cat >"$c/s.rs" <<'RS'
fn w(v: &Vauchi) {
    v.app_preferences();
    v.set_app_preferences(p);
}
RS
    base="$root/baseline.json"
    cat >"$base" <<'JSON'
{
  "totals": {
    "app_pref_callers_cli":   0,
    "app_pref_callers_total": 0
  }
}
JSON
    set +e
    "$SCRIPT" --check "$base" "$root" >/dev/null 2>&1
    rc=$?
    set -e
    assert_eq "check: exit 1 when count exceeds baseline" "1" "$rc"
    rm -rf "$root"
}

# ── 7. --check ratchet: exits zero AT/BELOW baseline ──────────────────
test_check_at_or_below_baseline_passes() {
    root=$(mktemp -d)
    c="$root/cli/src"; mkdir -p "$c"
    cat >"$c/s.rs" <<'RS'
fn w(v: &Vauchi) {
    v.app_preferences();
    v.set_app_preferences(p);
}
RS
    base_at="$root/at.json"
    cat >"$base_at" <<'JSON'
{
  "totals": {
    "app_pref_callers_cli":   2,
    "app_pref_callers_total": 2
  }
}
JSON
    base_below="$root/below.json"
    cat >"$base_below" <<'JSON'
{
  "totals": {
    "app_pref_callers_cli":   5,
    "app_pref_callers_total": 5
  }
}
JSON
    set +e
    "$SCRIPT" --check "$base_at" "$root" >/dev/null 2>&1; rc_at=$?
    "$SCRIPT" --check "$base_below" "$root" >/dev/null 2>&1; rc_below=$?
    set -e
    assert_eq "check: exit 0 at baseline" "0" "$rc_at"
    assert_eq "check: exit 0 below baseline" "0" "$rc_below"
    rm -rf "$root"
}

# ── 8. --check missing baseline → exit 2 ──────────────────────────────
test_check_missing_baseline() {
    root=$(mktemp -d)
    set +e
    "$SCRIPT" --check "/does/not/exist/$$.json" "$root" >/dev/null 2>&1
    rc=$?
    set -e
    assert_eq "check: missing baseline → exit 2" "2" "$rc"
    rm -rf "$root"
}

# ── 9. JSON output parses ─────────────────────────────────────────────
test_json_validity() {
    root=$(mktemp -d)
    out=$("$SCRIPT" "$root")
    if printf '%s' "$out" | python3 -m json.tool >/dev/null 2>&1; then
        printf '  PASS json: parses as JSON\n'; pass=$((pass + 1))
    else
        printf '  FAIL json: invalid JSON\n    output: %s\n' "$out" >&2
        fail=$((fail + 1))
    fi
    rm -rf "$root"
}

# ── 10. Bad workspace root → exit 2 ───────────────────────────────────
test_bad_workspace() {
    set +e
    "$SCRIPT" "/does/not/exist/$$" >/dev/null 2>&1
    rc=$?
    set -e
    assert_eq "bad workspace: exit 2" "2" "$rc"
}

# ── run ───────────────────────────────────────────────────────────────
test_empty_workspace
test_cli_sentinel
test_ios_sentinel
test_excluded_paths
test_total_sums
test_check_above_baseline_fails
test_check_at_or_below_baseline_passes
test_check_missing_baseline
test_json_validity
test_bad_workspace

printf '\n%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
