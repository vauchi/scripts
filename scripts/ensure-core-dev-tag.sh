#!/bin/sh
# SPDX-FileCopyrightText: 2026 Mattia Egloff <mattia.egloff@pm.me>
#
# SPDX-License-Identifier: GPL-3.0-or-later
#
# Cut a core dev tag when main has moved past the newest one.
#
# Consumers pin core by tag, so they can only ever move to a tag that
# exists. `auto-tag` fires on a version bump, and an ordinary merge does
# not bump the version — so main can advance indefinitely with no tag to
# adopt. On 2026-08-09 cli!498 sat blocked for exactly that reason: the
# symbols it needed were merged, no tag contained them, and unblocking
# took a manual release step.
#
# Tag cadence is therefore the real constraint on consumer freshness, and
# this makes it a property of the schedule rather than of someone
# noticing. Intended for a scheduled CI job.
#
# Dev tags are the cheap rung: lightweight pipeline, no publish, no
# mobile-binding trigger (see `just release-rc` for the next rung up).
# That is what makes automatic cutting proportionate here — this must
# never be pointed at rc/prod.
#
# Usage:
#   ensure-core-dev-tag.sh [--dry-run] [workspace_root]
#
# Exit: 0 whether or not a tag was needed; 1 if cutting failed; 2 on
#       usage/IO error.
#
# Portability: POSIX shell + git.
set -eu

DRY=0
if [ "${1:-}" = "--dry-run" ]; then
    DRY=1
    shift
fi

WORKSPACE_ROOT="${1:-$(CDPATH='' cd -- "$(dirname -- "$0")/../.." && pwd)}"
WORKSPACE_ROOT=$(CDPATH='' cd -- "$WORKSPACE_ROOT" && pwd)
CORE="$WORKSPACE_ROOT/core"

[ -d "$CORE/.git" ] || {
    printf 'ensure-core-dev-tag: no core checkout at %s\n' "$CORE" >&2
    exit 2
}

git -C "$CORE" fetch --tags --quiet origin

BASE=$(git -C "$CORE" rev-parse origin/main)
LATEST=$(git -C "$CORE" tag --sort=-creatordate | head -1)

if [ -z "$LATEST" ]; then
    printf 'ensure-core-dev-tag: core has no tags at all — cut the first by hand\n' >&2
    exit 2
fi

behind=$(git -C "$CORE" rev-list --count "$LATEST".."$BASE" 2>/dev/null || echo 0)

printf 'core main %s, newest tag %s, %s commit(s) untagged\n' \
    "$(git -C "$CORE" rev-parse --short origin/main)" "$LATEST" "$behind"

if [ "$behind" -eq 0 ]; then
    printf 'nothing to cut — every merged commit is reachable from a tag\n'
    exit 0
fi

if [ "$DRY" -eq 1 ]; then
    printf 'would cut a dev tag so consumers can adopt those %s commit(s)\n' "$behind"
    exit 0
fi

# Delegate to the existing release path rather than minting a tag here:
# `_release-tag` owns the suffix arithmetic, the pre-push gate and the
# annotation format, and duplicating any of that would drift from it.
printf 'cutting a dev tag via just release-dev core\n'
if ! (cd "$WORKSPACE_ROOT" && just release-dev core); then
    printf 'ensure-core-dev-tag: release-dev failed\n' >&2
    exit 1
fi

git -C "$CORE" fetch --tags --quiet origin
printf 'newest tag is now %s\n' "$(git -C "$CORE" tag --sort=-creatordate | head -1)"
