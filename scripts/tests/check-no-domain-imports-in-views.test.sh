#!/usr/bin/env bash
# SPDX-FileCopyrightText: 2026 Mattia Egloff <mattia.egloff@pm.me>
#
# SPDX-License-Identifier: GPL-3.0-or-later

# Regression suite for check-no-domain-imports-in-views.sh.
# Exercises the warn-only default, --strict mode, and the allowlist.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT="$SCRIPT_DIR/../check-no-domain-imports-in-views.sh"

pass=0
fail=0

mk_workspace() {
    local root="$1"
    mkdir -p "$root/android/app/src/main/kotlin/app/vauchi/ui/coreui"
    mkdir -p "$root/android/app/src/main/kotlin/app/vauchi/ui/components"
}

write_file() {
    local path="$1"
    shift
    mkdir -p "$(dirname "$path")"
    printf '%s\n' "$@" > "$path"
}

assert_exit() {
    local name="$1" want="$2" got="$3"
    if [[ "$want" == "$got" ]]; then
        printf '  PASS %s\n' "$name"
        pass=$((pass + 1))
    else
        printf '  FAIL %s — want exit %s, got %s\n' "$name" "$want" "$got" >&2
        fail=$((fail + 1))
    fi
}

assert_contains() {
    local name="$1" needle="$2" haystack="$3"
    if [[ "$haystack" == *"$needle"* ]]; then
        printf '  PASS %s\n' "$name"
        pass=$((pass + 1))
    else
        printf '  FAIL %s — missing %q\n    output: %s\n' "$name" "$needle" "$haystack" >&2
        fail=$((fail + 1))
    fi
}

# ── 1. Clean tree — no violations, exits 0 ───────────────────────────
test_clean_tree() {
    local root
    root="$(mktemp -d)"
    trap 'rm -rf "$root"' RETURN
    mk_workspace "$root"
    write_file "$root/android/app/src/main/kotlin/app/vauchi/ui/CleanScreen.kt" \
        'package app.vauchi.ui' \
        'import uniffi.vauchi_platform.ScreenModel' \
        'import uniffi.vauchi_platform.UserAction'
    set +e
    out="$("$SCRIPT" "$root" 2>&1)"
    rc=$?
    set -e
    assert_exit "clean tree exit 0" 0 "$rc"
    assert_contains "clean tree OK message" "OK: no view-layer" "$out"
}

# ── 2. Mobile* import in a top-level screen — warn-only by default ──
test_mobile_import_warn() {
    local root
    root="$(mktemp -d)"
    trap 'rm -rf "$root"' RETURN
    mk_workspace "$root"
    write_file "$root/android/app/src/main/kotlin/app/vauchi/ui/ThemeSettingsScreen.kt" \
        'package app.vauchi.ui' \
        'import uniffi.vauchi_platform.MobileTheme'
    set +e
    out="$("$SCRIPT" "$root" 2>&1)"
    rc=$?
    set -e
    assert_exit "Mobile* import warn-only exit 0" 0 "$rc"
    assert_contains "warn header present" "WARN" "$out"
    assert_contains "violation cited" "MobileTheme" "$out"
}

# ── 3. Same violation with --strict — exits 1 ────────────────────────
test_mobile_import_strict() {
    local root
    root="$(mktemp -d)"
    trap 'rm -rf "$root"' RETURN
    mk_workspace "$root"
    write_file "$root/android/app/src/main/kotlin/app/vauchi/ui/ThemeSettingsScreen.kt" \
        'package app.vauchi.ui' \
        'import uniffi.vauchi_platform.MobileTheme'
    set +e
    out="$("$SCRIPT" "$root" --strict 2>&1)"
    rc=$?
    set -e
    assert_exit "Mobile* import --strict exit 1" 1 "$rc"
    assert_contains "FAIL header present" "FAIL" "$out"
}

# ── 4. coreui/ allowlist — Mobile* is allowed there ──────────────────
test_coreui_allowlist() {
    local root
    root="$(mktemp -d)"
    trap 'rm -rf "$root"' RETURN
    mk_workspace "$root"
    write_file "$root/android/app/src/main/kotlin/app/vauchi/ui/coreui/ScreenRenderer.kt" \
        'package app.vauchi.ui.coreui' \
        'import uniffi.vauchi_platform.MobileContact'
    set +e
    out="$("$SCRIPT" "$root" --strict 2>&1)"
    rc=$?
    set -e
    assert_exit "coreui/ allowlist exit 0" 0 "$rc"
}

# ── 5. MainViewModel.kt allowlist — Mobile* is tolerated ─────────────
test_mainviewmodel_allowlist() {
    local root
    root="$(mktemp -d)"
    trap 'rm -rf "$root"' RETURN
    mk_workspace "$root"
    write_file "$root/android/app/src/main/kotlin/app/vauchi/ui/MainViewModel.kt" \
        'package app.vauchi.ui' \
        'import uniffi.vauchi_platform.MobileContact'
    set +e
    out="$("$SCRIPT" "$root" --strict 2>&1)"
    rc=$?
    set -e
    assert_exit "MainViewModel.kt allowlist exit 0" 0 "$rc"
}

# ── 6. Identity conditional in a top-level screen — strict fails ─────
test_identity_branch_strict() {
    local root
    root="$(mktemp -d)"
    trap 'rm -rf "$root"' RETURN
    mk_workspace "$root"
    write_file "$root/android/app/src/main/kotlin/app/vauchi/ui/SomeScreen.kt" \
        'package app.vauchi.ui' \
        'fun render() {' \
        '    if (repository.hasIdentity()) doX()' \
        '}'
    set +e
    out="$("$SCRIPT" "$root" --strict 2>&1)"
    rc=$?
    set -e
    assert_exit "identity branch strict exit 1" 1 "$rc"
    assert_contains "identity violation cited" "hasIdentity" "$out"
}

# ── 7. Biometric outcome enum in a screen — strict fails ─────────────
test_biometric_branch_strict() {
    local root
    root="$(mktemp -d)"
    trap 'rm -rf "$root"' RETURN
    mk_workspace "$root"
    write_file "$root/android/app/src/main/kotlin/app/vauchi/ui/AuthScreen.kt" \
        'package app.vauchi.ui' \
        'fun render() {' \
        '    when (val o = MobileBiometricUnlockOutcome.UNLOCKED) {}' \
        '}'
    set +e
    out="$("$SCRIPT" "$root" --strict 2>&1)"
    rc=$?
    set -e
    assert_exit "biometric branch strict exit 1" 1 "$rc"
}

# ── 8. Missing android/ tree — silent no-op ──────────────────────────
test_missing_tree_noop() {
    local root
    root="$(mktemp -d)"
    trap 'rm -rf "$root"' RETURN
    set +e
    out="$("$SCRIPT" "$root" --strict 2>&1)"
    rc=$?
    set -e
    assert_exit "missing android/ exit 0" 0 "$rc"
}

# ── 9. Bad usage — missing argument ──────────────────────────────────
test_usage_error() {
    set +e
    out="$("$SCRIPT" 2>&1)"
    rc=$?
    set -e
    assert_exit "missing argument exit 2" 2 "$rc"
    assert_contains "usage hint shown" "Usage" "$out"
}

test_clean_tree
test_mobile_import_warn
test_mobile_import_strict
test_coreui_allowlist
test_mainviewmodel_allowlist
test_identity_branch_strict
test_biometric_branch_strict
test_missing_tree_noop
test_usage_error

echo
printf 'check-no-domain-imports-in-views: %d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
