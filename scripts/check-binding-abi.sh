#!/usr/bin/env bash
# SPDX-FileCopyrightText: 2026 Mattia Egloff <mattia.egloff@pm.me>
#
# SPDX-License-Identifier: GPL-3.0-or-later

# check-binding-abi.sh — Diff UniFFI symbols referenced by generated
# Kotlin/Swift bindings against the dynamic exports of the packaged
# native artifact (.so / .a / .dylib). Fails with a clear report if
# either side carries a symbol the other does not.
#
# Moves the "stale artifact / stale bindings" failure point from
# "first UniFFI call on device" (UnsatisfiedLinkError) to
# "before the artifact leaves the build host".
#
# Plan: _private/docs/planning/todo/2026-04-20-frontend-correctness-strategy-plan.md
# Task 2.1.
#
# Usage:
#   check-binding-abi.sh --platform {android|ios} \
#                        --artifact <.so|.a|.dylib path> \
#                        --bindings <vauchi_platform.kt|.swift path>
#
# Exit codes:
#   0 — binding and artifact symbol sets match exactly
#   1 — mismatch (diff printed to stderr)
#   2 — invocation error (missing args, tool not found)

set -euo pipefail

SYMBOL_PREFIX="uniffi_vauchi_platform"

die() {
    printf 'check-binding-abi: %s\n' "$*" >&2
    exit 2
}

usage() {
    sed -n 's/^# \{0,1\}//p' "${BASH_SOURCE[0]}" | sed '/^---$/q' >&2
    exit 2
}

platform=""
artifact=""
bindings=""

while (( $# > 0 )); do
    case "$1" in
        --platform)  platform="${2:?--platform requires a value}"; shift 2 ;;
        --artifact)  artifact="${2:?--artifact requires a value}"; shift 2 ;;
        --bindings)  bindings="${2:?--bindings requires a value}"; shift 2 ;;
        -h|--help)   usage ;;
        *)           die "unknown argument: $1" ;;
    esac
done

[[ -n "$platform" ]]  || die "missing --platform"
[[ -n "$artifact" ]]  || die "missing --artifact"
[[ -n "$bindings" ]]  || die "missing --bindings"
[[ -f "$artifact" ]]  || die "artifact not found: $artifact"
[[ -f "$bindings" ]]  || die "bindings not found: $bindings"

# ── Symbol extraction ────────────────────────────────────────────

# From Kotlin / Swift bindings. Both languages reference the same
# prefix; the regex covers every UniFFI-generated shape we see in
# the current bindings (fn/checksum × func/method/constructor/
# clone/free). Matches are deduped via `sort -u`.
extract_binding_symbols() {
    grep -oE "${SYMBOL_PREFIX}_[a-zA-Z0-9_]+" "$bindings" | sort -u
}

# From a packaged .so (Android). Uses the NDK's llvm-nm. Looks for
# dynamically-exported text symbols with the UniFFI prefix.
extract_android_so_symbols() {
    local nm_bin
    nm_bin=$(find_android_nm)
    [[ -n "$nm_bin" ]] || die "llvm-nm not found (set ANDROID_NDK_HOME or install NDK)"
    "$nm_bin" --dynamic "$artifact" \
        | awk '/ T '"${SYMBOL_PREFIX}_"'/ {print $NF}' \
        | sort -u
}

# From a packaged .a / .dylib (iOS / macOS). macOS `nm` is
# available out of the box. Symbols carry a leading underscore
# in Mach-O; strip it so the set comparison lines up with Android.
extract_ios_artifact_symbols() {
    command -v nm >/dev/null 2>&1 || die "nm not found"
    # `nm` prints "no symbols" to stderr for archive members that
    # contribute no exported symbols (every dep rlib in a fat
    # static library). Harmless; silence so the failure report
    # stays readable.
    nm -g "$artifact" 2>/dev/null \
        | awk '/ T _'"${SYMBOL_PREFIX}_"'/ {print $NF}' \
        | sed 's/^_//' \
        | sort -u
}

find_android_nm() {
    # Highest-trust sources first: explicit env vars.
    local candidates=(
        "${ANDROID_NDK_HOME:-}"
        "${ANDROID_NDK_ROOT:-}"
    )
    # Default Android Studio SDK locations — macOS + Linux. Pick
    # the newest NDK version present under each.
    for sdk_root in \
        "${ANDROID_HOME:-}" \
        "${ANDROID_SDK_ROOT:-}" \
        "$HOME/Library/Android/sdk" \
        "$HOME/Android/Sdk"
    do
        [[ -n "$sdk_root" && -d "$sdk_root/ndk" ]] || continue
        for ndk in "$sdk_root"/ndk/*; do
            [[ -d "$ndk" ]] && candidates+=("$ndk")
        done
    done
    for base in "${candidates[@]}"; do
        [[ -n "$base" ]] || continue
        for f in "$base/toolchains/llvm/prebuilt"/*/bin/llvm-nm; do
            [[ -x "$f" ]] && { printf '%s\n' "$f"; return 0; }
        done
    done
    # Fall back to PATH
    command -v llvm-nm || true
}

# ── Run the diff ─────────────────────────────────────────────────

binding_syms_file=$(mktemp)
artifact_syms_file=$(mktemp)
trap 'rm -f "$binding_syms_file" "$artifact_syms_file"' EXIT

extract_binding_symbols > "$binding_syms_file"

case "$platform" in
    android) extract_android_so_symbols > "$artifact_syms_file" ;;
    ios|macos) extract_ios_artifact_symbols > "$artifact_syms_file" ;;
    *)       die "unknown --platform '$platform' (want: android|ios|macos)" ;;
esac

# Only in bindings — bindings reference a symbol the artifact does
# not export. This is the failure mode that caused the
# 2026-04-20 Android startup crash (UnsatisfiedLinkError on
# `core_version`).
in_bindings_only=$(comm -23 "$binding_syms_file" "$artifact_syms_file")
# Only in artifact — artifact exports a symbol bindings never
# reference. Usually harmless (UniFFI runtime helpers), but we
# still fail hard so the build surfaces any generator drift.
in_artifact_only=$(comm -13 "$binding_syms_file" "$artifact_syms_file")

if [[ -z "$in_bindings_only" && -z "$in_artifact_only" ]]; then
    printf 'check-binding-abi: %s/%s — %d symbols match\n' \
        "$platform" "$(basename "$artifact")" \
        "$(wc -l < "$binding_syms_file" | tr -d ' ')"
    exit 0
fi

{
    printf 'check-binding-abi: ABI parity FAILED for %s (%s vs %s)\n' \
        "$platform" "$artifact" "$bindings"
    if [[ -n "$in_bindings_only" ]]; then
        printf '\n  Symbols referenced by bindings but NOT exported by artifact\n'
        printf '  (would UnsatisfiedLinkError / dyld error at runtime):\n'
        printf '    - %s\n' $in_bindings_only
    fi
    if [[ -n "$in_artifact_only" ]]; then
        printf '\n  Symbols exported by artifact but NOT referenced by bindings\n'
        printf '  (likely generator drift — bindings regenerated against an older build):\n'
        printf '    - %s\n' $in_artifact_only
    fi
} >&2

exit 1
