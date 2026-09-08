#!/usr/bin/env bash
# SPDX-FileCopyrightText: 2026 Mattia Egloff <mattia.egloff@pm.me>
#
# SPDX-License-Identifier: GPL-3.0-or-later
#
# Stale ci-template pin — VSP01: a repo's pinned `ci-templates-vYYYY.MM.N`
# ref must be among the most recent published tags. A pin that falls many
# releases behind silently ships an old lint/CI ruleset, so a fix merged to
# ci-templates never reaches the repo — surfacing later as a spurious
# pipeline failure. (Root cause of the 2026-07 `_private` doc-naming break:
# a pin 78 commits / several tags behind.)
# Rule page: _private/docs/lint-errors/vsp01-stale-ci-template-pin.md
# Self-test: scripts/tests/check-stale-ci-pin.test.sh
# Called by: `just session-end` and root CI — the recent-tags list is
#   generated with `git -C scripts tag --sort=-v:refname | head -N`.

set -euo pipefail

CI_YAML="${1:?usage: check-stale-ci-pin.sh <ci-yaml> <recent-tags-file> [label]}"
RECENT="${2:?usage: check-stale-ci-pin.sh <ci-yaml> <recent-tags-file> [label]}"
LABEL="${3:-$CI_YAML}"
errors=0
err() { printf '  %s\n' "$1" >&2; errors=$((errors + 1)); }

PAGE="_private/docs/lint-errors/vsp01-stale-ci-template-pin.md"

[ -f "$CI_YAML" ] || { echo "  (no CI yaml: $CI_YAML)"; exit 0; }
[ -f "$RECENT" ] || { echo "check-stale-ci-pin: recent-tags file not found: $RECENT" >&2; exit 2; }

# Strip comments before matching. A comment naming the tag that first
# carried a template is history, not a pin, and flagging it makes VSP01
# permanently red for a file nobody can fix without deleting the note.
# Anything outside a comment still counts — `ref:`, a variable, or a
# `git clone --branch` in a script line are all real pins.
pins="$(sed 's/#.*$//' "$CI_YAML" 2>/dev/null \
    | grep -oE 'ci-templates-v[0-9]+\.[0-9]+\.[0-9]+' \
    | sort -u || true)"
[ -n "$pins" ] || { echo "  no ci-template pins in $LABEL"; exit 0; }

while IFS= read -r pin; do
    [ -n "$pin" ] || continue
    if ! grep -qxF "$pin" "$RECENT"; then
        err "$LABEL: VSP01: pinned $pin is not among the latest ci-template tags — fix: bump to a current 'ci-templates-v*' tag. [$PAGE]"
    fi
done <<EOF
$pins
EOF

if [ "$errors" -eq 0 ]; then
    echo "  ci-template pin fresh ($LABEL)"
    exit 0
fi
echo "FAILED: $errors stale ci-template pin(s)." >&2
exit 1
