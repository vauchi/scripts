#!/usr/bin/env bash
# SPDX-FileCopyrightText: 2026 Mattia Egloff <mattia.egloff@pm.me>
#
# SPDX-License-Identifier: GPL-3.0-or-later

# audit-shell-surface.sh — Ratchet floor for the "frontends are shells"
# residual debt: everything left in the handwritten frontend trees that
# still knows about domain concepts. Two counter families:
#
#   1. Mobile* domain-type references in handwritten frontend source
#      (ios_mobile_type_refs / android_mobile_refs / macos_mobile_refs)
#      — the frontend-side half of the legacy domain-typed binding
#      surface. These replicate the EXACT counting method of the
#      sibling audit-mobile-surface.sh counters 6 / 7 / 7b (same
#      greps, same roots, same Generated//Libs/ exclusions) so both
#      scripts report identical live values; audit-mobile-surface.sh
#      has no --check mode, so the ratchet for them lives here.
#
#   2. hw_executor_domain_vocab — hardware-executor purity: lines
#      matching the closed domain deny-list (the same word set as
#      audit-frontend-vocab.sh) inside the frontend hardware-executor
#      files. Executors move bytes and hold OS handles; a domain word
#      in one means a domain concept leaked past the core boundary
#      into the shell's I/O edge.
#
# Enforces: ADR-043 Amendment 4 §4 and ADR-044 Amendment 1 §3
#           ("frontend is a pure renderer; no domain vocabulary in
#           frontend source"), extended to the hardware-executor edge.
#
# Origin: counters 1–3 replicate audit-mobile-surface.sh (plan
#         _private/docs/planning/todo/2026-05-11-pure-functional-core-program-plan.md);
#         the deny-list reuses audit-frontend-vocab.sh's word set
#         (design _private/docs/designs/2026-05-25-zero-domain-vocabulary-in-frontends-design.md).
#
# Usage:
#   audit-shell-surface.sh [workspace_root]
#       Emit the JSON snapshot on stdout. Exit 0 (the JSON is the
#       result); exit 2 only on internal error (bad workspace root).
#   audit-shell-surface.sh --check <baseline.json> [workspace_root]
#       Ratchet mode. Compare each current total against the baseline;
#       exit 1 if ANY total EXCEEDS its baseline value (a regression).
#       Counts at or below baseline pass (exit 0) — decreases are the
#       goal, never a failure.
#
# Default workspace_root: two levels up from this script (so
# scripts/scripts/audit-shell-surface.sh resolves to the workspace
# root).
#
# Hardware-executor file selection (hw_executor_domain_vocab):
#   ios/     ios/Vauchi/**/*.swift with BLE, Ble, Audio, Keychain, NFC
#            or Camera in the basename
#   macos/   macos/Vauchi/**/*.swift, same basenames
#   android/ android/app/src/main/**/*.kt with Ble, Audio, Nfc, Camera
#            or Keystore in the basename
# Test trees (/Tests/, /test/, /androidTest/, *Tests.swift, *Test.kt)
# are excluded everywhere. A missing tree contributes 0, so the script
# also runs in a single-repo CI checkout.
#
# Portability: POSIX shell + BSD/GNU/BusyBox-portable utilities only.
# No grep -P, no bash arrays, no GNU --include/--exclude, no mapfile.

set -euo pipefail

# ── arg parsing ───────────────────────────────────────────────────────
CHECK_MODE=0
BASELINE_FILE=""
if [ "${1:-}" = "--check" ]; then
    CHECK_MODE=1
    BASELINE_FILE="${2:-}"
    if [ -z "$BASELINE_FILE" ]; then
        printf 'audit-shell-surface: --check requires a baseline file\n' >&2
        exit 2
    fi
    if [ ! -f "$BASELINE_FILE" ]; then
        printf 'audit-shell-surface: baseline %s not found\n' "$BASELINE_FILE" >&2
        exit 2
    fi
    shift 2
fi

# ── locate workspace root ─────────────────────────────────────────────
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
DEFAULT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
WORKSPACE_ROOT="${1:-$DEFAULT_ROOT}"

if [ ! -d "$WORKSPACE_ROOT" ]; then
    printf 'audit-shell-surface: workspace_root %s is not a directory\n' \
        "$WORKSPACE_ROOT" >&2
    exit 2
fi
WORKSPACE_ROOT="$(cd "$WORKSPACE_ROOT" && pwd)"

# ── the closed domain deny-list ──────────────────────────────────────
# Identical to DOMAIN_WORDS in audit-frontend-vocab.sh — the two lists
# MUST stay in sync: this is the same deny-list enforced at a second
# surface (hardware executors instead of navigation literals). New
# domain words go to the glossary (_private/docs/CONTEXT.md), NEVER to
# an allow-list here (ADR-043 Am4 §4).
DOMAIN_WORDS='MyInfo|MyCard|Contacts|ContactDetail|ContactEdit|EntryDetail|GroupDetail|OpenContact|EditContact|OpenEntryDetail'

# ── repo-relative frontend source roots ──────────────────────────────
# Same roots as audit-mobile-surface.sh counters 6 / 7 / 7b.
IOS_SRC="$WORKSPACE_ROOT/ios/Vauchi"
MACOS_SRC="$WORKSPACE_ROOT/macos/Vauchi"
ANDROID_UI="$WORKSPACE_ROOT/android/app/src/main/kotlin/app/vauchi/ui"
ANDROID_SRC="$WORKSPACE_ROOT/android/app/src/main"

# ── counters 1–3: Mobile* domain-type references ─────────────────────
# Each block is a verbatim replica of the corresponding
# audit-mobile-surface.sh counter — keep the greps in sync.

# 1. iOS — Mobile* type-name references in *hand-written* Swift files.
#    Excludes `Generated/` (UniFFI-emitted binding mirrors) and `Libs/`
#    (local SPM checkout); both are binding-distribution artefacts.
ios_mobile_type_refs=0
if [ -d "$IOS_SRC" ]; then
    ios_mobile_type_refs=$(grep -rsE '\bMobile[A-Z]' "$IOS_SRC" 2>/dev/null \
        | grep -v '/Generated/' \
        | grep -cv '/Libs/' || true)
fi

# 2. Android — Mobile* references under the UI tree (audit-mobile-
#    surface.sh scopes this counter to kotlin/app/vauchi/ui with no
#    exclusions; replicated as-is).
android_mobile_refs=0
if [ -d "$ANDROID_UI" ]; then
    n=$(grep -rsE '\bMobile[A-Z]' "$ANDROID_UI" 2>/dev/null | wc -l || true)
    android_mobile_refs=$((n + 0))
fi

# 3. macOS — Mobile* type-name references in *hand-written* Swift
#    files. Same exclusions as iOS.
macos_mobile_refs=0
if [ -d "$MACOS_SRC" ]; then
    macos_mobile_refs=$(grep -rsE '\bMobile[A-Z]' "$MACOS_SRC" 2>/dev/null \
        | grep -v '/Generated/' \
        | grep -cv '/Libs/' || true)
fi

# ── counter 4: hardware-executor domain vocabulary ───────────────────
# Executor file path filters (matched against the full path; the
# hardware word must appear in the basename).
IOS_HW_RE='(BLE|Ble|Audio|Keychain|NFC|Camera)[^/]*\.swift$'
MACOS_HW_RE='(BLE|Ble|Audio|Keychain|NFC|Camera)[^/]*\.swift$'
ANDROID_HW_RE='(Ble|Audio|Nfc|Camera|Keystore)[^/]*\.kt$'

# executor_domain_vocab <src_root> <path_regex>
# Count lines matching the domain deny-list across the hardware-
# executor files under <src_root> (files whose path matches
# <path_regex>). Test trees are excluded. Missing root or no executor
# files → 0. `|| true` swallows the grep/xargs exit-1 on zero matches
# under `set -euo pipefail` (same pattern as audit-frontend-vocab.sh).
executor_domain_vocab() {
    root="$1"; path_re="$2"
    [ -d "$root" ] || { printf '0'; return; }
    files=$(find "$root" -type f 2>/dev/null \
        | grep -E "$path_re" \
        | grep -v '/Tests/' \
        | grep -v '/test/' \
        | grep -v '/androidTest/' \
        | grep -v 'Tests\.swift' \
        | grep -v 'Test\.kt' \
        || true)
    # Drop the empty line printf emits for an empty list.
    files=$(printf '%s\n' "$files" | grep . || true)
    [ -n "$files" ] || { printf '0'; return; }
    n=$(printf '%s\n' "$files" \
        | xargs grep -E "$DOMAIN_WORDS" 2>/dev/null \
        | wc -l || true)
    printf '%d' "$((n + 0))"
}

# Per-platform executor counts exist only to be summed into the single
# hw_executor_domain_vocab total.
hw_executor_vocab_ios=$(executor_domain_vocab "$IOS_SRC" "$IOS_HW_RE")
hw_executor_vocab_macos=$(executor_domain_vocab "$MACOS_SRC" "$MACOS_HW_RE")
hw_executor_vocab_android=$(executor_domain_vocab "$ANDROID_SRC" "$ANDROID_HW_RE")
hw_executor_domain_vocab=$((hw_executor_vocab_ios + hw_executor_vocab_macos + hw_executor_vocab_android))

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
    printf '    %-32s %d,\n' '"ios_mobile_type_refs":'     "$ios_mobile_type_refs"
    printf '    %-32s %d,\n' '"android_mobile_refs":'      "$android_mobile_refs"
    printf '    %-32s %d,\n' '"macos_mobile_refs":'        "$macos_mobile_refs"
    printf '    %-32s %d\n'  '"hw_executor_domain_vocab":' "$hw_executor_domain_vocab"
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
# baseline is a regression (the shell-surface ratchet may only drop).
# A baseline missing a key is treated as 0 (new counter → must be 0).
#
# baseline_value <key> — pull `"key": N` from the baseline JSON. POSIX
# awk, same shape as audit-frontend-vocab.sh's baseline_value.
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
        printf 'REGRESSION %s: baseline %d, now %d (shell-surface count must not rise)\n' \
            "$name" "$base" "$current" >&2
        regressions=$((regressions + 1))
    fi
}

check_one 'ios_mobile_type_refs'     "$ios_mobile_type_refs"
check_one 'android_mobile_refs'      "$android_mobile_refs"
check_one 'macos_mobile_refs'        "$macos_mobile_refs"
check_one 'hw_executor_domain_vocab' "$hw_executor_domain_vocab"

if [ "$regressions" -gt 0 ]; then
    printf 'audit-shell-surface: %d counter(s) exceeded baseline %s\n' \
        "$regressions" "$BASELINE_FILE" >&2
    exit 1
fi

printf 'audit-shell-surface: OK — all totals at or below baseline %s\n' \
    "$BASELINE_FILE"
exit 0
