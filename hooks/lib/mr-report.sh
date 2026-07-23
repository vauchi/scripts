#!/bin/bash
# SPDX-FileCopyrightText: 2026 Mattia Egloff <mattia.egloff@pm.me>
#
# SPDX-License-Identifier: GPL-3.0-or-later
#
# MR report + merged-branch guard for hooks/pre-push, extracted into its
# own script so it can be unit-tested (tests/mr-report.test.sh).
#
# Two failure modes this shape exists to prevent, both observed live:
#
#   1. glab's flags drift between releases — `--state=opened|merged` was
#      removed by glab 1.109. The old inline block discarded stderr, so a
#      hard CLI error was indistinguishable from "no MRs found": it
#      reported "No open MR" for a branch whose MR was open, and the
#      merged-branch guard below stopped firing at all, silently. A query
#      that FAILS is reported as a failure and never read as an absence.
#
#   2. `glab mr list` prints "No open merge requests match your search"
#      and exits 0 on an empty result, so emptiness cannot be tested with
#      -n. MR rows are matched by their leading `!<iid>` instead. Testing
#      -n here would make the merged-branch guard block every push.
#
# Usage: mr-report.sh <repo_root> <branch> [lookback_seconds]
# Exit:  0 = proceed with the push, 1 = push blocked.

set -u

REPO_ROOT="${1:?repo root required}"
BRANCH="${2:?branch required}"
LOOKBACK="${3:-120}"

[[ -z "$BRANCH" || "$BRANCH" == "main" || "$BRANCH" == "HEAD" ]] && exit 0

GLAB=${VAUCHI_GLAB_BIN:-glab}
command -v "$GLAB" >/dev/null 2>&1 || exit 0
cd "$REPO_ROOT" || exit 0

# Sets MR_ROWS to this branch's matching MR rows (empty when there are
# none). Returns 1 when the query itself failed, which callers must treat
# as "unknown", never as "none".
MR_ROWS=""
mrs_for_branch() {
    local out rc=0
    MR_ROWS=""
    out=$("$GLAB" mr list --source-branch="$BRANCH" "$@" 2>&1) || rc=$?
    if [[ $rc -ne 0 ]]; then
        printf 'WARNING: `glab mr list --source-branch=%s %s` failed — MR checks skipped:\n%s\n' \
            "$BRANCH" "$*" "$out" >&2
        return 1
    fi
    MR_ROWS=$(printf '%s\n' "$out" | grep -E '^![0-9]+' || true)
}

mrs_for_branch || exit 0
OPEN_MRS="$MR_ROWS"

if [[ -n "$OPEN_MRS" ]]; then
    echo "Open MRs on branch $BRANCH:"
    echo "$OPEN_MRS"
else
    echo "No open MR for branch $BRANCH"

    # Pushing to a branch whose MR already merged recreates it on the
    # remote and orphans the commits — they land in no MR at all.
    if mrs_for_branch --merged && [[ -n "$MR_ROWS" ]] &&
        [[ "${ALLOW_MERGED_BRANCH:-}" != "1" ]]; then
        echo ""
        echo "ERROR: Branch $BRANCH has a merged MR:"
        echo "$MR_ROWS"
        echo ""
        echo "Pushing to a merged branch silently orphans your commits."
        echo "Create a new branch instead:  git checkout -b <new-branch>"
        echo ""
        echo "To override: ALLOW_MERGED_BRANCH=1 git push"
        exit 1
    fi
    exit 0
fi

# Informational for a branch that still has an open MR: an MR merged
# during this push's own checks means the base moved under you.
SINCE=$(date -u -d "$LOOKBACK seconds ago" '+%Y-%m-%dT%H:%M:%SZ' 2>/dev/null || date -u -v-"${LOOKBACK}"S '+%Y-%m-%dT%H:%M:%SZ' 2>/dev/null || echo "")
[[ -z "$SINCE" ]] && exit 0
mrs_for_branch --merged || exit 0
[[ -z "$MR_ROWS" ]] && exit 0

RECENT=""
while IFS= read -r line; do
    IID=$(printf '%s' "$line" | grep -oE '^![0-9]+' | tr -d '!')
    [[ -z "$IID" ]] && continue
    MERGED_AT=$("$GLAB" api "projects/:id/merge_requests/$IID" 2>/dev/null | jq -r '.merged_at // ""' 2>/dev/null) || MERGED_AT=""
    [[ -n "$MERGED_AT" && "$MERGED_AT" > "$SINCE" ]] && RECENT="${RECENT}${line}"$'\n'
done <<<"$MR_ROWS"

if [[ -n "$RECENT" ]]; then
    echo ""
    echo "Recently merged MRs on branch $BRANCH:"
    printf '%s' "$RECENT"
fi
exit 0
