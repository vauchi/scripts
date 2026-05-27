#!/usr/bin/env bash
# SPDX-FileCopyrightText: 2026 Mattia Egloff <mattia.egloff@pm.me>
#
# SPDX-License-Identifier: GPL-3.0-or-later

# Sentinel regression suite for audit-dispatch-purity.sh — the
# dispatch-wrapper pass-through purity gate (ADR-043 Am3 §2 / L3.2).
#
# Per CC-20 / CC-21 these tests are NON-tautological: each builds a tiny
# synthetic dispatch-extension file, plants known sentinel lines, runs
# the real script, and asserts the gate COUNTS impurity signals
# (.filter, when(, String(format, .replace, switch, statement-if) and
# does NOT count the sanctioned pass-through unwrap idiom
# (`as? ... ?: unexpectedResult` in Kotlin, `guard case let ... else
# { throw }` in Swift). It also asserts the --check ratchet exits nonzero
# when planted impurity pushes a count above baseline, zero when at/below.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
SCRIPT="$SCRIPT_DIR/../audit-dispatch-purity.sh"

KT_REL="android/app/src/main/kotlin/app/vauchi/data/PlatformAppEngineDomainDispatch.kt"
SW_REL="ios/Vauchi/Services/PlatformAppEngine+DomainDispatch.swift"

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

mk_kt() { mkdir -p "$(dirname "$1/$KT_REL")"; cat > "$1/$KT_REL"; }
mk_sw() { mkdir -p "$(dirname "$1/$SW_REL")"; cat > "$1/$SW_REL"; }

# ── 1. Empty workspace → all zero, exit 0 ─────────────────────────────
test_empty_workspace() {
    root=$(mktemp -d)
    out=$("$SCRIPT" "$root"); rc=$?
    assert_eq "empty: exit 0" 0 "$rc"
    assert_eq "empty: android == 0" "0" "$(extract_counter "$out" impure_dispatch_lines_android)"
    assert_eq "empty: ios == 0"     "0" "$(extract_counter "$out" impure_dispatch_lines_ios)"
    assert_eq "empty: total == 0"   "0" "$(extract_counter "$out" impure_dispatch_lines_total)"
    rm -rf "$root"
}

# ── 2. Sanctioned pure idiom → 0 (false-positive guard) ───────────────
test_pure_idiom_scores_zero() {
    root=$(mktemp -d)
    mk_kt "$root" <<'KT'
fun PlatformAppEngine.getPublicId(): String {
    val result = dispatchDomainCommand(DomainCommand.GetPublicId)
    return (result as? DomainCommandResult.Text)?.value ?: unexpectedResult("GetPublicId")
}
fun PlatformAppEngine.createIdentity(name: String) {
    dispatchDomainCommand(DomainCommand.CreateIdentity(name))
}
KT
    mk_sw "$root" <<'SW'
func getPublicId() throws -> String {
    let result = try dispatchDomainCommand(command: .getPublicId)
    guard case let .text(value) = result else {
        throw MobileError.Other(detail: "GetPublicId: unexpected result variant")
    }
    return value
}
SW
    out=$("$SCRIPT" "$root")
    assert_eq "pure: android == 0" "0" "$(extract_counter "$out" impure_dispatch_lines_android)"
    assert_eq "pure: ios == 0"     "0" "$(extract_counter "$out" impure_dispatch_lines_ios)"
    rm -rf "$root"
}

# ── 3. Impure signals are counted ─────────────────────────────────────
test_impurity_counted() {
    root=$(mktemp -d)
    # 3 impure Kotlin lines: .filter, when (, String.format-ish .replace
    mk_kt "$root" <<'KT'
fun PlatformAppEngine.activeContacts(): List<MobileContact> {
    val result = dispatchDomainCommand(DomainCommand.GetContacts)
    return (result as? DomainCommandResult.Contacts)?.items?.filter { it.isActive } ?: emptyList()
}
fun PlatformAppEngine.label(state: MobileSyncState): String {
    return when (state) { is MobileSyncState.Idle -> "idle"; else -> "x" }
}
fun PlatformAppEngine.pretty(s: String): String = s.replace("_", " ")
KT
    # 2 impure Swift lines: switch, .map
    mk_sw "$root" <<'SW'
func names() throws -> [String] {
    let result = try dispatchDomainCommand(command: .getContacts)
    switch result { case .contacts(let c): return c.map { $0.name }; default: return [] }
}
SW
    out=$("$SCRIPT" "$root")
    a=$(extract_counter "$out" impure_dispatch_lines_android)
    i=$(extract_counter "$out" impure_dispatch_lines_ios)
    # android: .filter line + when( line + .replace line = 3
    assert_eq "impure: android counted (>=3)" "1" "$([ "$a" -ge 3 ] && echo 1 || echo 0)"
    # ios: switch line (also has .map) >= 1
    assert_eq "impure: ios counted (>=1)" "1" "$([ "$i" -ge 1 ] && echo 1 || echo 0)"
    rm -rf "$root"
}

# ── 4. Ratchet: impurity above baseline → exit 1 ──────────────────────
test_ratchet_blocks_regression() {
    root=$(mktemp -d)
    mk_kt "$root" <<'KT'
fun PlatformAppEngine.bad(): String = dispatchDomainCommand(DomainCommand.X).let { it.toString().uppercased() }
KT
    base=$(mktemp)
    cat > "$base" <<'JSON'
{ "totals": {
  "impure_dispatch_lines_android": 0,
  "impure_dispatch_lines_ios": 0,
  "impure_dispatch_lines_total": 0
} }
JSON
    set +e
    "$SCRIPT" --check "$base" "$root" >/dev/null 2>&1
    rc=$?
    set -e
    assert_eq "ratchet: regression exits 1" 1 "$rc"
    rm -rf "$root" "$base"
}

# ── 5. Ratchet: pure tree at baseline 0 → exit 0 ──────────────────────
test_ratchet_passes_when_pure() {
    root=$(mktemp -d)
    mk_kt "$root" <<'KT'
fun PlatformAppEngine.createIdentity(name: String) {
    dispatchDomainCommand(DomainCommand.CreateIdentity(name))
}
KT
    base=$(mktemp)
    cat > "$base" <<'JSON'
{ "totals": {
  "impure_dispatch_lines_android": 0,
  "impure_dispatch_lines_ios": 0,
  "impure_dispatch_lines_total": 0
} }
JSON
    set +e
    "$SCRIPT" --check "$base" "$root" >/dev/null 2>&1
    rc=$?
    set -e
    assert_eq "ratchet: pure passes (exit 0)" 0 "$rc"
    rm -rf "$root" "$base"
}

test_empty_workspace
test_pure_idiom_scores_zero
test_impurity_counted
test_ratchet_blocks_regression
test_ratchet_passes_when_pure

printf '\n%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
