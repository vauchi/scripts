#!/usr/bin/env bash
# SPDX-FileCopyrightText: 2026 Mattia Egloff <mattia.egloff@pm.me>
#
# SPDX-License-Identifier: GPL-3.0-or-later

# Sentinel regression suite for audit-frontend-vocab.sh — the
# frontend-source domain-vocabulary deny-list (ADR-043 Am4 §4,
# ADR-044 Am1 §3).
#
# Per CC-20 / CC-21 these tests are NON-tautological: each builds a tiny
# synthetic frontend tree, plants known sentinel lines, runs the real
# script, and asserts the gate COUNTS the domain nav literals and does
# NOT count the documented false-positive shapes (t("contacts"),
# searchContacts(), MobileError, navigate calls with a variable arg, and
# non-domain screen names like "Settings"). It also asserts the --check
# ratchet exits nonzero when a planted literal pushes the count above a
# tiny baseline and exits zero when at/below baseline.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
SCRIPT="$SCRIPT_DIR/../audit-frontend-vocab.sh"

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

# extract_counter <json> <key> — grab `"key": N` value from the JSON.
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

# ── 1. Empty workspace → all zero, valid JSON, exit 0 ─────────────────
test_empty_workspace() {
    root=$(mktemp -d)
    out=$("$SCRIPT" "$root"); rc=$?
    assert_eq "empty: exit 0" 0 "$rc"
    assert_eq "empty: android == 0" "0" "$(extract_counter "$out" nav_domain_literals_android)"
    assert_eq "empty: ios == 0"     "0" "$(extract_counter "$out" nav_domain_literals_ios)"
    assert_eq "empty: total == 0"   "0" "$(extract_counter "$out" nav_domain_literals_total)"
    rm -rf "$root"
}

# ── 2. Android sentinel — counts domain nav literals, skips the rest ──
# Plants 3 true positives (navigateTo("Contacts"),
# navigateToScreenWithParam("ContactDetail",…), navigateTo("MyInfo"))
# and 4 documented false-positives that must NOT count:
#   t("contacts")        — localized tab label (lowercase, no navigate)
#   searchContacts()     — method name, not a quoted literal
#   MobileError          — plumbing type, out of scope
#   navigateTo(variant)  — variable arg, not a quoted literal
#   navigateTo("Settings") — navigate call but NON-domain word
test_android_sentinel() {
    root=$(mktemp -d)
    dir="$root/android/app/src/main/kotlin/app/vauchi"
    mkdir -p "$dir"
    cat >"$dir/MainActivity.kt" <<'KT'
fun wire() {
    coreAppViewModel.navigateTo("Contacts")
    coreAppViewModel.navigateToScreenWithParam("ContactDetail", "contact_id", id)
    coreAppViewModel.navigateTo("MyInfo")
    // false positives below must NOT count
    val label = t("contacts")
    viewModel.searchContacts()
    val e: MobileError = mapErr()
    coreAppViewModel.navigateTo(variant)
    coreAppViewModel.navigateTo("Settings")
}
KT
    out=$("$SCRIPT" "$root")
    assert_eq "android: counts 3 domain nav literals" \
        "3" "$(extract_counter "$out" nav_domain_literals_android)"
    rm -rf "$root"
}

# ── 3. iOS sentinel — Swift dict-key + screenJson literal forms ───────
# Two true positives (navigateToScreen(["ContactDetail": …]),
# navigateToScreen(["EntryDetail": …])) plus the same false-positive set.
test_ios_sentinel() {
    root=$(mktemp -d)
    dir="$root/ios/Vauchi/CoreUI"
    mkdir -p "$dir"
    cat >"$dir/AppViewModel.swift" <<'SW'
func route() {
    navigateToScreen(["ContactDetail": ["contact_id": contactId]])
    navigateToScreen(["EntryDetail": ["field_id": fieldId]])
    // false positives below must NOT count
    let label = t("contacts")
    viewModel.searchContacts()
    let e: MobileError = mapErr()
    coreVM.navigateTo(screenJson: "\"Settings\"")
}
SW
    out=$("$SCRIPT" "$root")
    assert_eq "ios: counts 2 domain nav literals (dict-key form)" \
        "2" "$(extract_counter "$out" nav_domain_literals_ios)"
    rm -rf "$root"
}

# ── 4. Excluded subpaths do NOT contribute ───────────────────────────
# Generated/, uniffi/, Libs/, build/, locales/, and test trees may echo
# domain nav literals (binding mirrors, vendored SPM, generated nav
# tables) — none must count.
test_excluded_paths() {
    root=$(mktemp -d)
    real="$root/ios/Vauchi/CoreUI"
    gen="$root/ios/Vauchi/Generated"
    libs="$root/ios/Vauchi/Libs/VauchiPlatformLocal"
    tests="$root/ios/VauchiTests"
    abuild="$root/android/app/src/main/kotlin/app/vauchi/build"
    locales="$root/android/app/src/main/locales"
    mkdir -p "$real" "$gen" "$libs" "$tests" "$abuild" "$locales"
    # One real hit.
    cat >"$real/AppViewModel.swift" <<'SW'
func route() { navigateToScreen(["ContactDetail": ["contact_id": id]]) }
SW
    # Decoys in excluded trees — each carries domain nav literals.
    cat >"$gen/vauchi_nav.swift" <<'SW'
func g() { navigateToScreen(["ContactEdit": [:]]) }
func g2() { navigateTo("MyCard") }
SW
    cat >"$libs/spm_nav.swift" <<'SW'
func l() { navigateTo("Contacts") }
SW
    cat >"$tests/NavTests.swift" <<'SW'
func t() { navigateToScreen(["GroupDetail": [:]]) }
SW
    cat >"$abuild/Generated.kt" <<'KT'
fun b() { navigateTo("Contacts") }
KT
    cat >"$locales/en.kt" <<'KT'
fun loc() { navigateTo("MyInfo") }
KT
    out=$("$SCRIPT" "$root")
    assert_eq "excluded: only the 1 real ios hit counts" \
        "1" "$(extract_counter "$out" nav_domain_literals_ios)"
    assert_eq "excluded: android build/locales excluded == 0" \
        "0" "$(extract_counter "$out" nav_domain_literals_android)"
    rm -rf "$root"
}

# ── 5. Total = android + ios ──────────────────────────────────────────
test_total_sums() {
    root=$(mktemp -d)
    a="$root/android/app/src/main/kotlin/app/vauchi"
    i="$root/ios/Vauchi/CoreUI"
    mkdir -p "$a" "$i"
    cat >"$a/Main.kt" <<'KT'
fun w() {
    navigateTo("Contacts")
    navigateToScreenWithParam("ContactEdit", "contact_id", id)
}
KT
    cat >"$i/Vm.swift" <<'SW'
func r() { navigateToScreen(["EntryDetail": [:]]) }
SW
    out=$("$SCRIPT" "$root")
    assert_eq "total: 2 android + 1 ios == 3" \
        "3" "$(extract_counter "$out" nav_domain_literals_total)"
    rm -rf "$root"
}

# ── 6. --check ratchet: exits nonzero ABOVE baseline ──────────────────
# Tiny baseline of total=1; plant 2 literals → total=2 > 1 → exit 1.
test_check_above_baseline_fails() {
    root=$(mktemp -d)
    a="$root/android/app/src/main/kotlin/app/vauchi"
    mkdir -p "$a"
    cat >"$a/Main.kt" <<'KT'
fun w() {
    navigateTo("Contacts")
    navigateTo("MyInfo")
}
KT
    base="$root/baseline.json"
    cat >"$base" <<'JSON'
{
  "schema_version": 1,
  "totals": {
    "nav_domain_literals_android": 1,
    "nav_domain_literals_ios": 0,
    "nav_domain_literals_total": 1
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
# Same 2 literals, baseline total=2 (at) and a separate run with
# baseline total=5 (below) — both must pass with exit 0.
test_check_at_or_below_baseline_passes() {
    root=$(mktemp -d)
    a="$root/android/app/src/main/kotlin/app/vauchi"
    mkdir -p "$a"
    cat >"$a/Main.kt" <<'KT'
fun w() {
    navigateTo("Contacts")
    navigateTo("MyInfo")
}
KT
    base_at="$root/baseline_at.json"
    cat >"$base_at" <<'JSON'
{
  "totals": {
    "nav_domain_literals_android": 2,
    "nav_domain_literals_ios": 0,
    "nav_domain_literals_total": 2
  }
}
JSON
    base_below="$root/baseline_below.json"
    cat >"$base_below" <<'JSON'
{
  "totals": {
    "nav_domain_literals_android": 5,
    "nav_domain_literals_ios": 0,
    "nav_domain_literals_total": 5
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

# ── 8. --check missing baseline file → exit 2 ─────────────────────────
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
test_android_sentinel
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
