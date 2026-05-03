#!/usr/bin/env bash
# SPDX-FileCopyrightText: 2026 Mattia Egloff <mattia.egloff@pm.me>
#
# SPDX-License-Identifier: GPL-3.0-or-later

# check-text-literal-count.sh — Forbid the count of hardcoded
# user-visible `Text("Foo")` SwiftUI literals from increasing.
#
# Usage: check-text-literal-count.sh <repo_root> <path1> [<path2> ...]
# Example: check-text-literal-count.sh /Users/me/Workspace/vauchi/ios Vauchi/Views/
#          check-text-literal-count.sh /…/macos Vauchi/Views/ Vauchi/CoreUI/ Vauchi/VauchiApp.swift
#
# Background: per ADR-021/043 + ADR-038 (Humble UI + Design Tokens),
# every user-visible string lives in `locales/*.json` and is read via
# `LocalizationService.shared.t("foo.key")`. A literal `Text("Foo")`
# bypasses i18n and pins the string to one language — invisible to
# the locale-store sync.
#
# The G3 sweep in `2026-05-02-ios-humble-ui-deep-retirement` and the
# G4 sweep in `2026-05-02-macos-humble-ui-retirement` track the
# current counts. This script ratchets them down: the count in the
# `<repo_root>/.text-literal-baseline` file is the cap. Any MR that
# raises the count fails CI; any MR that lowers it is encouraged to
# also lower the baseline.
#
# Detection regex: `Text\("[A-Z][a-zA-Z ]+"\)`
# - The `[A-Z]` initial filter excludes lowercase identifiers
#   (`Text(label)` reads from a variable, not a literal).
# - `[a-zA-Z ]+` excludes punctuation (which is a heuristic for
#   "this is a real user-visible sentence" vs glyphs like `Text("+")`,
#   `Text("\(count)")`, etc.).
# This is the same regex the humble-UI audit uses to baseline counts.
#
# Source records:
#   _private/docs/problems/2026-05-02-ios-humble-ui-deep-retirement/   (G3)
#   _private/docs/problems/2026-05-02-macos-humble-ui-retirement/      (G4)

set -euo pipefail

if [ $# -lt 2 ]; then
    echo "Usage: $0 <repo_root> <path1> [<path2> ...]" >&2
    echo "Example: $0 /Users/me/.../ios Vauchi/Views/" >&2
    exit 2
fi

REPO_ROOT="$1"
shift

if [ ! -d "$REPO_ROOT" ]; then
    echo "Error: $REPO_ROOT is not a directory" >&2
    exit 2
fi

BASELINE_FILE="$REPO_ROOT/.text-literal-baseline"

if [ ! -f "$BASELINE_FILE" ]; then
    echo "Error: missing baseline at $BASELINE_FILE" >&2
    echo "Initialise it with the current count, then ratchet down on" >&2
    echo "every retirement MR." >&2
    exit 2
fi

# Strip blank lines and `#` comments; expect a single integer.
BASELINE_RAW="$(grep -vE '^[[:space:]]*(#|$)' "$BASELINE_FILE" | head -1 | tr -d '[:space:]')"

if ! [[ "$BASELINE_RAW" =~ ^[0-9]+$ ]]; then
    echo "Error: $BASELINE_FILE must contain a single integer (got: '$BASELINE_RAW')" >&2
    exit 2
fi
BASELINE="$BASELINE_RAW"

# Resolve search paths. Each path may be a directory (recursed) or a
# single file. Skip non-existent paths with a warning rather than
# failing — frontends evolve and the recipe shouldn't trip on a
# missing dir.
SEARCH_TARGETS=()
for p in "$@"; do
    full="$REPO_ROOT/$p"
    if [ -e "$full" ]; then
        SEARCH_TARGETS+=("$full")
    else
        echo "WARN: skipping missing path $p" >&2
    fi
done

if [ ${#SEARCH_TARGETS[@]} -eq 0 ]; then
    echo "Error: no existing search paths in $REPO_ROOT" >&2
    exit 2
fi

# Count `Text("...")` matches. `grep -E` is POSIX-portable (no `-P`).
# `--include='*.swift'` is honoured by both BSD and GNU grep; alpine
# CI's busybox grep does NOT honour it, but this script only runs in
# the local-dev / macOS-CI lint stage which has BSD or GNU grep.
#
# The `|| true` guards against `grep` exiting 1 when the count is
# legitimately 0 (a desired final state). Under `set -o pipefail`
# that exit code would propagate and kill the script.
COUNT="$({ grep -rE 'Text\("[A-Z][a-zA-Z ]+"\)' \
    --include='*.swift' \
    "${SEARCH_TARGETS[@]}" 2>/dev/null || true; } \
    | wc -l | tr -d '[:space:]')"

if [ "$COUNT" -gt "$BASELINE" ]; then
    echo "FAIL: hardcoded Text(\"...\") count rose from $BASELINE → $COUNT in:"
    for t in "${SEARCH_TARGETS[@]}"; do
        echo "  $t"
    done
    echo
    echo "Each user-visible string must come from LocalizationService.t(key)"
    echo "with the key sourced from locales/*.json (ADR-038)."
    echo
    echo "If a new literal is genuinely platform-required (debug-only,"
    echo "pre-binding fallback), wrap the value in a constant or"
    echo "Text(LocalizationService.shared.t(\"foo.key\")) instead."
    echo
    echo "Audit the diff with:"
    printf '  grep -rE '\''Text\\("[A-Z][a-zA-Z ]+"\\)'\'' --include='\''*.swift'\'' '
    for t in "${SEARCH_TARGETS[@]}"; do
        printf '%s ' "$t"
    done
    echo
    exit 1
fi

if [ "$COUNT" -lt "$BASELINE" ]; then
    echo "OK: hardcoded Text(\"...\") count $COUNT (baseline $BASELINE)"
    echo "  → ratchet baseline down: echo $COUNT > $BASELINE_FILE"
    exit 0
fi

echo "OK: hardcoded Text(\"...\") count matches baseline ($COUNT)"
exit 0
