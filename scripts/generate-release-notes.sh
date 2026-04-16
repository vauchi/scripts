#!/usr/bin/env bash
# SPDX-FileCopyrightText: 2026 Mattia Egloff <mattia.egloff@pm.me>
# SPDX-License-Identifier: GPL-3.0-or-later
#
# Generate release notes from git log between two tags.
# Usage: generate-release-notes.sh [repo] [from-tag] [to-tag]

set -euo pipefail

REPO="${1:-core}"
TO_TAG="${3:-HEAD}"

if [ -z "${2:-}" ]; then
  FROM_TAG=$(git -C "$REPO" tag -l 'v[0-9]*.[0-9]*.[0-9]' \
    --sort=-v:refname | head -2 | tail -1)
  if [ -z "$FROM_TAG" ]; then
    echo "Cannot auto-detect previous tag." >&2
    echo "Usage: $0 [repo] <from-tag> [to-tag]" >&2
    exit 1
  fi
else
  FROM_TAG="$2"
fi

echo "# Release Notes: ${TO_TAG}"
echo ""
echo "Changes since ${FROM_TAG}:"
echo ""

for type_label in \
  "feat:Features" "fix:Bug Fixes" "refactor:Refactoring" \
  "docs:Documentation" "test:Tests" "chore:Maintenance" \
  "tidy:Code Cleanup"; do
  TYPE="${type_label%%:*}"
  LABEL="${type_label#*:}"
  COMMITS=$(git -C "$REPO" log "${FROM_TAG}..${TO_TAG}" \
    --oneline --grep="^${TYPE}:" --format="- %s" 2>/dev/null \
    || true)
  if [ -n "$COMMITS" ]; then
    echo "## ${LABEL}"
    echo ""
    echo "$COMMITS" | sed "s/^- ${TYPE}: /- /"
    echo ""
  fi
done
