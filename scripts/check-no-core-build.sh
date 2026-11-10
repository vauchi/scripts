#!/usr/bin/env bash
# SPDX-FileCopyrightText: 2026 Mattia Egloff <mattia.egloff@pm.me>
#
# SPDX-License-Identifier: GPL-3.0-or-later
#
# VCI01 (ADR-025): a binding repository's CI never builds a Core crate; it
# consumes Core's published bindings and libraries. A repo's own wrapper
# crate is fine (qt-display's thin Rust crate, for one): only builds of
# vauchi-core, vauchi-app, vauchi-platform or vauchi-cabi count.
#
# Usage: check-no-core-build.sh <repo-dir> <baseline-file>
#
# Scans .gitlab-ci.yml, ci/**/*.yml and scripts/**/*.sh. The baseline lists
# known builds as "<repo> <file> <command>", one line per occurrence; it may
# only shrink. A build it does not list, or more copies than it lists, fails.

set -eu

REPO_DIR="${1:-}"
BASELINE="${2:-}"
if [ -z "$REPO_DIR" ] || [ ! -d "$REPO_DIR" ] || [ -z "$BASELINE" ] || [ ! -f "$BASELINE" ]; then
    echo "check-no-core-build: usage: $0 <repo-dir> <baseline-file> (both must exist)" >&2
    exit 1
fi
REPO="$(basename "$(cd "$REPO_DIR" && pwd)")"
# ADR-078 renames linux-gtk and linux-qt (private#1029); the baseline keeps
# the names it was written with until the workspace follows.
case "$REPO" in
    gtk-display) REPO=linux-gtk ;;
    qt-display) REPO=linux-qt ;;
esac

SUBCOMMAND='(^|[^A-Za-z0-9_-])cargo([[:space:]]+\+[^[:space:]]+)?[[:space:]]+(ndk[^|;&]*[[:space:]]build|xwin[[:space:]]+build|build|test|check|run|rustc|install|nextest)([[:space:]]|$)'
CORE_CRATE='(-p|--package)[[:space:]]+(vauchi-core|vauchi-app|vauchi-platform|vauchi-cabi)([^A-Za-z0-9_-]|$)'

found="$(mktemp)"
allowed="$(mktemp)"
trap 'rm -f "$found" "$allowed"' EXIT

(
    cd "$REPO_DIR"
    {
        [ -f .gitlab-ci.yml ] && echo .gitlab-ci.yml
        [ -d ci ] && find ci -type f \( -name '*.yml' -o -name '*.yaml' \)
        [ -d scripts ] && find scripts -type f -name '*.sh'
    } | sort | while IFS= read -r file; do
        grep -E "$SUBCOMMAND" "$file" | grep -E "$CORE_CRATE" \
            | sed -e 's/^[[:space:]]*//' -e 's/^- //' -e 's/[[:space:]]*$//' \
            | sed "s|^|$REPO $file |" || true
    done
) | sort > "$found"

grep -E "^$REPO " "$BASELINE" | sed 's/[[:space:]]*$//' | sort > "$allowed" || true

# Each found command, its count, and how many copies the baseline allows.
over="$(sort "$found" | uniq -c | while read -r count key; do
    permitted=$(grep -c -x -F -- "$key" "$allowed" || true)
    if [ "$count" -gt "$permitted" ]; then
        printf '  %s (found %s, baseline allows %s)\n' "$key" "$count" "$permitted"
    fi
done)"

if [ -n "$over" ]; then
    echo "check-no-core-build (VCI01, ADR-025): $REPO's CI builds a Core crate:" >&2
    printf '%s\n' "$over" >&2
    echo "Consume Core's published package instead (see _private/docs/lint-errors/vci01-cargo-in-binding-repos.md)." >&2
    exit 1
fi
echo "check-no-core-build: $REPO builds no Core crate beyond its baseline"
