#!/usr/bin/env bash
# SPDX-FileCopyrightText: 2026 Mattia Egloff <mattia.egloff@pm.me>
#
# SPDX-License-Identifier: GPL-3.0-or-later

# audit-frontend-vocab.sh — Frontend-source domain-vocabulary deny-list.
# The cross-language analogue of
# core/vauchi-app/tests/it/wire_humble_keys_tests.rs (the *wire-side*
# deny-list): this is the *frontend-source-side* deny-list. It greps
# handwritten Swift/Kotlin for domain screen/action names used as
# navigation string literals and emits JSON counts — a ratchet floor
# that may DROP as Lever 1 retires the calls, never RISE.
#
# Enforces: ADR-043 Amendment 4 §4 (frontend-source deny-list) and
#           ADR-044 Amendment 1 §3 (frontend-source deny-list for the
#           navigation / screen-id vocabulary). "Frontend is a pure
#           renderer; no domain vocabulary in frontend source."
#
# Origin: _private/docs/designs/2026-05-25-zero-domain-vocabulary-in-frontends-design.md
#         (Refinement 2026-05-26, §1 — the enforcement spec).
#
# SCOPE — this script counts exactly ONE category:
#   nav_domain_literals — a domain screen/action word appearing as a
#   double-quoted STRING LITERAL on a line that also contains a
#   navigate*( call. Real patterns in this repo:
#       navigateTo("Contacts")                              (Kotlin)
#       navigateToScreenWithParam("ContactDetail", …)       (Kotlin)
#       navigateToScreen(["ContactDetail": …])              (Swift dict key)
#       navigateTo(screenJson: "\"More\"")                  (Swift)
#
# Deliberately NOT counted here: Mobile* domain *type* references
# (MobileContact, MobileFieldType, …). The sibling script
# audit-mobile-surface.sh already ratchets `ios_mobile_type_refs` /
# `android_mobile_refs` for the binding surface. The exemption-aware
# refinement of THAT counter (excluding plumbing Mobile* such as
# MobileError, and the ADR-031 PERMITTED_UNIFFI_OBJECTS peers — design
# Refinement §1(b)) is a SEPARATE follow-up. Counting Mobile* here too
# would double-count against audit-mobile-surface.sh's existing floors.
#
# Usage:
#   audit-frontend-vocab.sh [workspace_root]
#       Emit the JSON snapshot on stdout. Exit 0 (the JSON is the
#       result); exit 2 only on internal error (bad workspace root).
#   audit-frontend-vocab.sh --check <baseline.json> [workspace_root]
#       Ratchet mode. Compare each current total against the baseline;
#       exit 1 if ANY total EXCEEDS its baseline value (a regression).
#       Counts at or below baseline pass (exit 0).
#
# Default workspace_root: two levels up from this script (so
# scripts/scripts/audit-frontend-vocab.sh resolves to .../vauchi-1/).
#
# Handwritten frontend source counted:
#   android/app/src/main   (Kotlin)
#   ios/Vauchi             (Swift)
# Excluded subpaths (binding mirrors / generated / vendored / locales /
# tests): /Generated/, /uniffi/, /Libs/, /build/, /locales/, and test
# trees (/test/, /androidTest/, /Tests/, *Tests.swift, *Test.kt).
#
# Portability: POSIX shell + BSD/GNU/BusyBox-portable utilities only.
# No grep -P, no bash arrays, no GNU --include/--exclude, no mapfile.
# Verified inside alpine:3.21 (BusyBox grep/awk).

set -euo pipefail

# ── arg parsing ───────────────────────────────────────────────────────
CHECK_MODE=0
BASELINE_FILE=""
if [ "${1:-}" = "--check" ]; then
    CHECK_MODE=1
    BASELINE_FILE="${2:-}"
    if [ -z "$BASELINE_FILE" ]; then
        printf 'audit-frontend-vocab: --check requires a baseline file\n' >&2
        exit 2
    fi
    if [ ! -f "$BASELINE_FILE" ]; then
        printf 'audit-frontend-vocab: baseline %s not found\n' "$BASELINE_FILE" >&2
        exit 2
    fi
    shift 2
fi

# ── locate workspace root ─────────────────────────────────────────────
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
DEFAULT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
WORKSPACE_ROOT="${1:-$DEFAULT_ROOT}"

if [ ! -d "$WORKSPACE_ROOT" ]; then
    printf 'audit-frontend-vocab: workspace_root %s is not a directory\n' \
        "$WORKSPACE_ROOT" >&2
    exit 2
fi
WORKSPACE_ROOT="$(cd "$WORKSPACE_ROOT" && pwd)"

# ── the closed domain deny-list ──────────────────────────────────────
# Domain screen/action words that must never appear as a navigation
# string literal in handwritten frontend source. New domain words go
# to the glossary (_private/docs/CONTEXT.md), NEVER to an allow-list
# here — that is what makes the purge non-reversible (ADR-043 Am4 §4,
# same rationale as Wire Humble). Anchored as an ERE alternation,
# matched only when double-quoted (see nav_domain_literals below).
DOMAIN_WORDS='MyInfo|MyCard|Contacts|ContactDetail|ContactEdit|EntryDetail|GroupDetail|OpenContact|EditContact|OpenEntryDetail'

# ── exclusion filter ─────────────────────────────────────────────────
# Drop binding mirrors, generated code, vendored SPM, gradle output,
# locale tables, and test trees. Applied as a `grep -v` chain on the
# `path:lineno:line` output of the recursive grep (BusyBox-safe — no
# --exclude). Each pattern is a fixed substring of the path prefix.
strip_excluded() {
    grep -v '/Generated/' \
        | grep -v '/uniffi/' \
        | grep -v '/Libs/' \
        | grep -v '/build/' \
        | grep -v '/locales/' \
        | grep -v '/test/' \
        | grep -v '/androidTest/' \
        | grep -v '/Tests/' \
        | grep -v 'Tests\.swift' \
        | grep -v 'Test\.kt' \
        || true
}

# ── core counter ──────────────────────────────────────────────────────
# nav_domain_literals <src_root>
# Count lines under <src_root> that (a) contain a navigate*( call AND
# (b) contain a deny-listed domain word wrapped in double quotes. The
# double-quote anchoring is what keeps method names (searchContacts),
# localized labels (t("contacts") — lowercase, and not in a navigate
# call), and Mobile* types out of the count. Missing root → 0.
#
# Two-stage grep: first narrow to navigate*( lines (cheap), then match
# the quoted domain word. Both stages are POSIX ERE (grep -E), no -P.
nav_domain_literals() {
    root="$1"
    [ -d "$root" ] || { printf '0'; return; }
    n=$(grep -rsnE 'navigate[A-Za-z]*\(' "$root" 2>/dev/null \
        | strip_excluded \
        | grep -cE "\"(${DOMAIN_WORDS})\"" || true)
    printf '%s' "${n:-0}"
}

# ── repo-relative frontend source roots ──────────────────────────────
ANDROID_SRC="$WORKSPACE_ROOT/android/app/src/main"
IOS_SRC="$WORKSPACE_ROOT/ios/Vauchi"

# ── counters ─────────────────────────────────────────────────────────
nav_domain_literals_android=$(nav_domain_literals "$ANDROID_SRC")
nav_domain_literals_ios=$(nav_domain_literals "$IOS_SRC")
nav_domain_literals_total=$((nav_domain_literals_android + nav_domain_literals_ios))

# ── timestamp (BSD + GNU + BusyBox safe) ─────────────────────────────
captured_at=$(date -u +%Y-%m-%dT%H:%M:%SZ)

# ── render JSON to a variable ─────────────────────────────────────────
# Plain printf — no jq. All values are integers, so no escaping needed.
# The last total omits its trailing comma. In --check mode the snapshot
# is recomputed from the live tree (captured_at differs from baseline;
# only the totals are compared).
emit_json() {
    printf '{\n'
    printf '  "schema_version": 1,\n'
    printf '  "captured_at": "%s",\n' "$captured_at"
    printf '  "workspace_root": "%s",\n' "$WORKSPACE_ROOT"
    printf '  "totals": {\n'
    printf '    %-32s %d,\n' '"nav_domain_literals_android":' "$nav_domain_literals_android"
    printf '    %-32s %d,\n' '"nav_domain_literals_ios":'     "$nav_domain_literals_ios"
    printf '    %-32s %d\n'  '"nav_domain_literals_total":'   "$nav_domain_literals_total"
    printf '  }\n'
    printf '}\n'
}

# ── plain (snapshot) mode ─────────────────────────────────────────────
if [ "$CHECK_MODE" -eq 0 ]; then
    emit_json
    exit 0
fi

# ── --check (ratchet) mode ────────────────────────────────────────────
# Read each baseline total and compare. A current total ABOVE its
# baseline is a regression (the deny-list ratchet may only drop). A
# baseline missing a key is treated as 0 (new counter → must be 0).
#
# baseline_value <key> — pull `"key": N` from the baseline JSON. POSIX
# awk, same shape as audit-mobile-surface.test.sh's extract_counter.
baseline_value() {
    awk -v k="\"$1\"" '
        $1 ~ k {
            v = $0
            sub(/.*:[[:space:]]+/, "", v)
            sub(/,$/, "", v)
            print v + 0
            exit
        }
    ' "$BASELINE_FILE"
}

regressions=0
check_one() {
    name="$1"
    current="$2"
    base=$(baseline_value "$name")
    base="${base:-0}"
    if [ "$current" -gt "$base" ]; then
        printf 'REGRESSION %s: baseline %d, now %d (deny-list count must not rise)\n' \
            "$name" "$base" "$current" >&2
        regressions=$((regressions + 1))
    fi
}

check_one 'nav_domain_literals_android' "$nav_domain_literals_android"
check_one 'nav_domain_literals_ios'     "$nav_domain_literals_ios"
check_one 'nav_domain_literals_total'   "$nav_domain_literals_total"

if [ "$regressions" -gt 0 ]; then
    printf 'audit-frontend-vocab: %d counter(s) exceeded baseline %s\n' \
        "$regressions" "$BASELINE_FILE" >&2
    exit 1
fi

printf 'audit-frontend-vocab: OK — all totals at or below baseline %s\n' \
    "$BASELINE_FILE"
exit 0
