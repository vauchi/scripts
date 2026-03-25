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

errors=0
while IFS= read -r symbol; do
    [ -z "$symbol" ] && continue
    # Search for the symbol in all specified directories
    # Exclude binary files, .git, and the manifest itself
    matches=$(grep -rFl "$symbol" "${SEARCH_DIRS[@]}" \
        --include='*.rs' --include='*.cpp' --include='*.h' \
        --include='*.py' --include='*.md' --include='*.yml' \
        --include='*.yaml' --include='*.toml' --include='*.json' \
        --include='*.sh' --include='*.txt' \
        2>/dev/null || true)

    if [ -n "$matches" ]; then
        echo "STALE REFERENCE: '$symbol' found in:"
        while IFS= read -r m; do echo "  $m"; done <<< "$matches"
        errors=$((errors + 1))
    fi
done <<< "$symbols"

if [ "$errors" -eq 0 ]; then
    echo "OK: No stale references to removed symbols"
    exit 0
else
    echo ""
    echo "FAILED: $errors removed symbol(s) still referenced"
    echo "Update the files above or remove them from the manifest if intentional."
    exit 1
fi
