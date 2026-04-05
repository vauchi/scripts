#!/usr/bin/env bash
# SPDX-FileCopyrightText: 2026 Mattia Egloff <mattia.egloff@pm.me>
# SPDX-License-Identifier: GPL-3.0-or-later
#
# Portable shell linter — catches GNU-vs-BSD patterns that shellcheck misses.
# Called by: pre-commit hook (staged .sh and .just files)
# Also runnable standalone: ./check-portable-shell.sh [file ...]
#
# Complements shellcheck (which catches shell-language bashisms) with checks
# for external-command portability (grep -P, \s in sed, echo -e, etc.).
# See: .claude/rules/portable-shell.md

set -euo pipefail

VIOLATIONS=0
CHECKED=0

check_file() {
    local file="$1"
    local line_no=0
    local found=0

    while IFS= read -r line; do
        line_no=$((line_no + 1))

        # Skip comments and empty lines
        [[ "$line" =~ ^[[:space:]]*# ]] && continue
        [[ -z "$line" ]] && continue

        # Skip lines with inline suppression, string literals, or regex tests.
        # Use "# portable-shell-ok" to suppress false positives on specific lines.
        # shellcheck disable=SC2016
        if [[ "$line" =~ portable-shell-ok ]] \
            || [[ "$line" =~ ^[[:space:]]*[\'\"] ]] \
            || [[ "$line" =~ '=~' ]]; then
            continue
        fi

        # grep -P (GNU Perl regex — not available on macOS BSD grep)
        if [[ "$line" =~ grep[[:space:]]+-[a-zA-Z]*P ]]; then
            printf '  %s:%d: %s\n' "$file" "$line_no" 'grep -P (GNU Perl regex)' # portable-shell-ok
            printf '    Use: grep -E or just grep (ripgrep)\n'
            found=1
        fi

        # echo -e (non-POSIX — behavior varies across shells and platforms)
        if [[ "$line" =~ echo[[:space:]]+-e[[:space:]] ]]; then
            printf '  %s:%d: %s\n' "$file" "$line_no" 'echo -e (non-POSIX)' # portable-shell-ok
            printf '    Use: printf "%%b\\n" instead\n'
            found=1
        fi

        # \s in grep/sed (non-POSIX regex class — fails on macOS sed)
        # Only flag when used as a command argument, not in Python/jq contexts
        if [[ "$line" =~ \\s ]] && [[ "$line" =~ (grep|sed|awk) ]]; then
            # Exclude Python raw strings, jq, and inline-disable comments
            if [[ ! "$line" =~ (r\'|r\"|python|\\.jq|portable-shell-ok) ]]; then
                printf '  %s:%d: %s\n' "$file" "$line_no" '\s in grep/sed (non-POSIX)' # portable-shell-ok
                printf '    Use: [[:space:]] instead\n'
                found=1
            fi
        fi

        # readlink -f (GNU-only — macOS ships BSD readlink without -f)
        if [[ "$line" =~ readlink[[:space:]]+-f ]]; then
            printf '  %s:%d: %s\n' "$file" "$line_no" 'readlink -f (GNU-only)' # portable-shell-ok
            printf '    Use: realpath or manual resolution\n'
            found=1
        fi

        # stat -c (GNU format flag — macOS uses stat -f)
        if [[ "$line" =~ stat[[:space:]]+-c ]]; then
            # Allow if there's a fallback on the same line
            if [[ ! "$line" =~ stat[[:space:]]+-f ]]; then
                printf '  %s:%d: %s\n' "$file" "$line_no" 'stat -c (GNU-only, no fallback)' # portable-shell-ok
                printf '    Use: stat -f (macOS) with || fallback\n'
                found=1
            fi
        fi

    done < "$file"

    CHECKED=$((CHECKED + 1))
    if [[ "$found" -eq 1 ]]; then
        VIOLATIONS=$((VIOLATIONS + 1))
    fi
}

# If arguments given, check those files. Otherwise, check staged files.
if [[ $# -gt 0 ]]; then
    files=("$@")
else
    # Get staged .sh and script files
    mapfile -t files < <(git diff --cached --name-only --diff-filter=ACM 2>/dev/null \
        | grep -E '\.(sh|bash)$' || true)

    # Also check staged .just files (extract shell blocks)
    mapfile -t just_files < <(git diff --cached --name-only --diff-filter=ACM 2>/dev/null \
        | grep -E '\.just$' || true)
    files+=("${just_files[@]}")
fi

for f in "${files[@]}"; do
    [[ -f "$f" ]] || continue
    check_file "$f"
done

if [[ "$VIOLATIONS" -gt 0 ]]; then
    echo ""
    printf 'FAILED: %d file(s) with non-portable shell patterns.\n' "$VIOLATIONS"
    echo "See: .claude/rules/portable-shell.md"
    exit 1
fi

if [[ "$CHECKED" -gt 0 ]]; then
    printf '  Portable shell OK (%d file(s) checked)\n' "$CHECKED"
fi
