#!/usr/bin/env bash
# SPDX-FileCopyrightText: 2026 Mattia Egloff <mattia.egloff@pm.me>
# SPDX-License-Identifier: GPL-3.0-or-later
#
# Detect hardcoded visual values that should use design tokens.
# Requires: ripgrep (rg)
#
# Environment variables:
#   TOKEN_LINT_PATHS      Space-separated directories to scan (required)
#   TOKEN_LINT_GLOBS      Space-separated file globs, e.g. "*.swift" "*.kt" (required)
#   TOKEN_LINT_EXCLUDES   Space-separated glob patterns to exclude (optional)

set -euo pipefail

if [ -z "${TOKEN_LINT_PATHS:-}" ]; then
  echo "Error: TOKEN_LINT_PATHS is not set." >&2
  echo "Usage: TOKEN_LINT_PATHS=src TOKEN_LINT_GLOBS='*.css' bash $0" >&2
  exit 2
fi

if [ -z "${TOKEN_LINT_GLOBS:-}" ]; then
  echo "Error: TOKEN_LINT_GLOBS is not set." >&2
  exit 2
fi

if ! command -v rg &>/dev/null; then
  echo "Error: ripgrep (rg) is required but not found." >&2
  exit 2
fi

# --- Build rg arguments ----------------------------------------------------

rg_args=()

# Include file type globs
for glob in $TOKEN_LINT_GLOBS; do
  rg_args+=(--glob "$glob")
done

# Default excludes: token definitions, generated, tests, lock files
default_excludes=(
  "!**/tokens.json"
  "!**/tokens.css"
  "!**/themes.json"
  "!**/generated/**"
  "!**/tests/**"
  "!**/*_test.*"
  "!**/*_tests.*"
  "!**/*Test.*"
  "!**/*Tests.*"
  "!**/*spec.*"
  "!**/package-lock.json"
  "!**/Cargo.lock"
  "!**/__Snapshots__/**"
  "!**/snapshots/**"
  "!**/build/**"
  "!**/node_modules/**"
)

for pat in "${default_excludes[@]}"; do
  rg_args+=(--glob "$pat")
done

# User excludes
for pat in ${TOKEN_LINT_EXCLUDES:-}; do
  rg_args+=(--glob "!$pat")
done

# --- Patterns ---------------------------------------------------------------

patterns=(
  "#[0-9a-fA-F]{3,8}\\b"
  "[0-9]+px"
  "[0-9]+\\.dp\\b"
  "[0-9]+\\.sp\\b"
  "\\.system\\(size:\\s*[0-9]"
)

# --- Scan -------------------------------------------------------------------

tmpfile=$(mktemp)
trap 'rm -f "$tmpfile"' EXIT

search_paths=()
for p in $TOKEN_LINT_PATHS; do
  search_paths+=("$p")
done

for pattern in "${patterns[@]}"; do
  rg --no-heading --line-number --with-filename \
    "${rg_args[@]}" \
    -e "$pattern" \
    "${search_paths[@]}" 2>/dev/null || true
done > "$tmpfile"

# --- Filter out comments ----------------------------------------------------

filtered=$(mktemp)
trap 'rm -f "$tmpfile" "$filtered"' EXIT

while IFS= read -r line; do
  # Extract the matched source line (everything after file:line:)
  source_line="${line#*:*:}"
  # Strip leading whitespace
  trimmed="${source_line#"${source_line%%[![:space:]]*}"}"

  # Skip comment lines
  case "$trimmed" in
    //*) continue ;;
    '#'*) continue ;;
    '/*'*) continue ;;
    '*'*) continue ;;
  esac

  echo "$line"
done < "$tmpfile" | sort -u > "$filtered"

# --- Output -----------------------------------------------------------------

violation_count=$(wc -l < "$filtered" | tr -d ' ')
file_count=0

if [ "$violation_count" -gt 0 ]; then
  cat "$filtered"
  file_count=$(cut -d: -f1 "$filtered" | sort -u | wc -l | tr -d ' ')
fi

echo ""
echo "${violation_count} violations found in ${file_count} files"

if [ "$violation_count" -gt 0 ]; then
  exit 1
else
  exit 0
fi
