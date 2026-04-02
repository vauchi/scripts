#!/usr/bin/env bash
# SPDX-FileCopyrightText: 2026 Mattia Egloff <mattia.egloff@pm.me>
# SPDX-License-Identifier: GPL-3.0-or-later

# check-removed-symbols.sh — Detect stale references to removed features.
#
# Searches source files, tests, docs, and CI configs for identifiers that
# have been removed from vauchi-core. The Rust compiler catches code references;
# this script catches non-compilable references (docs, comments, test strings,
# CI configs, design docs, headers).
#
# Usage:
#   check-removed-symbols.sh <manifest_file> [search_dirs...]
#
# Example:
#   check-removed-symbols.sh ../../removed-symbols.txt src/ tests/ design/ include/
#
# Manifest format (one per line, # comments allowed):
#   tor_settings          # Removed 2026-03 — replaced by OHTTP relay config
#   TorSettings           # PascalCase variant
#   "Tor Settings"        # UI label variant

set -euo pipefail

MANIFEST="${1:?Usage: check-removed-symbols.sh <manifest_file> [search_dirs...]}"
shift
SEARCH_DIRS=("${@:-.}")

if [ ! -f "$MANIFEST" ]; then
    echo "No manifest at $MANIFEST — skipping stale-reference check"
    exit 0
fi

# Strip comments and blank lines from manifest
symbols=$(grep -v '^\s*#' "$MANIFEST" | grep -v '^\s*$' | sed 's/\s*#.*//' | tr -d '"' || true)

if [ -z "$symbols" ]; then
    echo "Manifest is empty — nothing to check"
    exit 0
fi

# Write symbols to temp file for single-pass grep
sym_file=$(mktemp)
trap 'rm -f "$sym_file"' EXIT
printf '%s\n' "$symbols" > "$sym_file"

# Fast path: check all symbols in one pass using find + grep -f
# (avoids GNU grep --include dependency — works with busybox and macOS)
stale_files=$(find "${SEARCH_DIRS[@]}" -type f \( \
    -name '*.rs' -o -name '*.cpp' -o -name '*.h' \
    -o -name '*.py' -o -name '*.md' -o -name '*.yml' \
    -o -name '*.yaml' -o -name '*.toml' -o -name '*.json' \
    -o -name '*.sh' -o -name '*.txt' \) \
    -exec grep -lFf "$sym_file" {} + 2>/dev/null || true)

if [ -z "$stale_files" ]; then
    echo "OK: No stale references to removed symbols"
    exit 0
fi

# Detailed per-symbol report (only on failure)
errors=0
while IFS= read -r symbol; do
    [ -z "$symbol" ] && continue
    sym_matches=$(find "${SEARCH_DIRS[@]}" -type f \( \
        -name '*.rs' -o -name '*.cpp' -o -name '*.h' \
        -o -name '*.py' -o -name '*.md' -o -name '*.yml' \
        -o -name '*.yaml' -o -name '*.toml' -o -name '*.json' \
        -o -name '*.sh' -o -name '*.txt' \) \
        -exec grep -lF "$symbol" {} + 2>/dev/null || true)

    if [ -n "$sym_matches" ]; then
        echo "STALE REFERENCE: '$symbol' found in:"
        printf '%s\n' "$sym_matches" | while IFS= read -r m; do printf '  %s\n' "$m"; done
        errors=$((errors + 1))
    fi
done < "$sym_file"

if [ "$errors" -eq 0 ]; then
    echo "OK: No stale references to removed symbols"
    exit 0
else
    echo ""
    echo "FAILED: $errors removed symbol(s) still referenced"
    echo "Update the files above or remove them from the manifest if intentional."
    exit 1
fi
