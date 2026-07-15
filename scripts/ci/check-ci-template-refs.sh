#!/usr/bin/env bash
# SPDX-FileCopyrightText: 2026 Mattia Egloff <mattia.egloff@pm.me>
#
# SPDX-License-Identifier: GPL-3.0-or-later

# Self-healing check: every .gitlab-ci.yml include ref pointing to
# vauchi/scripts must match the VAUCHI_SCRIPTS_REF variable declared in
# the same file. This prevents drift when bumping the shared template
# version (previously required edits in ~20 files).

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WORKSPACE_ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)"

FAIL=0

while IFS= read -r file; do
    declared_ref=$(grep -E '^  VAUCHI_SCRIPTS_REF:' "$file" 2>/dev/null | sed -E 's/.*VAUCHI_SCRIPTS_REF:[[:space:]]*"([^"]+)".*/\1/' | head -n1 || true)
    if [ -z "$declared_ref" ]; then
        continue
    fi

    bad_refs=$(grep -nE "ref:\s*ci-templates-" "$file" | grep -v "ref: ${declared_ref}" || true)
    if [ -n "$bad_refs" ]; then
        echo "ERROR: $file declares VAUCHI_SCRIPTS_REF=${declared_ref} but contains mismatched include refs:"
        echo "$bad_refs"
        FAIL=1
    fi
done < <(find "$WORKSPACE_ROOT" -maxdepth 2 -name '.gitlab-ci.yml' -not -path '*/.worktrees/*' | sort)

if [ "$FAIL" -ne 0 ]; then
    echo "Template reference drift detected. Run the bump recipe to align all refs."
    exit 1
fi

echo "All .gitlab-ci.yml template refs match their VAUCHI_SCRIPTS_REF."
