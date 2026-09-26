#!/bin/sh
# SPDX-FileCopyrightText: 2026 Mattia Egloff <mattia.egloff@pm.me>
#
# SPDX-License-Identifier: GPL-3.0-or-later
#
# Stale-base guard for hooks/pre-push, extracted into its own script so it
# can be unit-tested (tests/stale-base-guard.test.sh). If the checked-out
# feature branch is behind origin/main, rebase it onto origin/main and
# block the push so the user re-pushes the rebased branch.
#
# Two safety gates keep it from ever touching work it was not asked to
# (backlog 2026-07-11-prepush-hook-rebases-on-tag-push):
#   1. A tag-only push carries no branch ref — it must never rebase the
#      working branch. Cutting a release or a rollback-anchor tag is a
#      moment a dirty tree is plausible; the old guard rebased anyway and
#      could shred uncommitted work via a conflicting autostash pop.
#   2. A dirty working tree is never rebased — the hook must never
#      autostash a contributor's uncommitted work as a push side effect.
#
# Usage: stale-base-guard.sh <repo_root>   (pre-push specs on stdin)
#   stdin: git pre-push feed, one "<lref> <lsha> <rref> <rsha>" per ref.
# Exit:  0 = proceed with the push, 1 = push blocked.

set -u

repo_root="${1:?repo root required}"
push_specs="$(cat)"

branch="$(git -C "$repo_root" rev-parse --abbrev-ref HEAD 2>/dev/null || true)"

# The guard only concerns a real feature-branch checkout.
if [ -z "$branch" ] || [ "$branch" = "main" ] || [ "$branch" = "HEAD" ]; then
    exit 0
fi

# Gate 1: a branch ref must actually be among the pushed refs. A tag-only
# push (only refs/tags/*), or a deletion (all-zero local sha), must not
# trigger a rebase of the working branch.
pushing_branch=false
while read -r local_ref local_sha remote_ref _rest; do
    [ -z "$local_ref" ] && continue
    case "$local_sha" in
        *[!0]*) : ;;      # a real object id → create/update
        *) continue ;;    # all-zero (or empty) → a deletion
    esac
    case "$remote_ref" in
        refs/heads/*) pushing_branch=true; break ;;
    esac
done <<EOF
$push_specs
EOF
[ "$pushing_branch" = true ] || exit 0

# Self-healing: unshallow if needed, then a normal fetch. Never use
# --depth on local dev repos — it progressively cuts history.
if git -C "$repo_root" rev-parse --is-shallow-repository 2>/dev/null | grep -q true; then
    git -C "$repo_root" fetch --unshallow origin main --quiet 2>/dev/null \
        || git -C "$repo_root" fetch origin main --quiet 2>/dev/null || true
else
    git -C "$repo_root" fetch origin main --quiet 2>/dev/null || true
fi

origin_main="$(git -C "$repo_root" rev-parse origin/main 2>/dev/null || true)"
[ -n "$origin_main" ] || exit 0

merge_base="$(git -C "$repo_root" merge-base HEAD "$origin_main" 2>/dev/null || true)"
[ -n "$merge_base" ] || exit 0
[ "$merge_base" != "$origin_main" ] || exit 0   # already rebased on main

behind="$(git -C "$repo_root" rev-list --count "$merge_base".."$origin_main" 2>/dev/null || echo '?')"

# Gate 2: never rebase a dirty tree — blocking beats autostashing WIP.
if [ -n "$(git -C "$repo_root" status --porcelain 2>/dev/null)" ]; then
    echo ""
    echo "BLOCKED: Branch is ${behind} commit(s) behind origin/main, and the"
    echo "  working tree has uncommitted changes. Refusing to auto-rebase a"
    echo "  dirty tree — it would stash your work and can lose it on a"
    echo "  conflicting pop. Commit or stash first, then rebase:"
    echo "    git stash && git rebase origin/main && git stash pop"
    exit 1
fi

echo ""
echo "  Branch is ${behind} commit(s) behind origin/main — rebasing..."
if git -C "$repo_root" rebase origin/main --quiet 2>/dev/null; then
    echo "  Rebased successfully."
    echo ""
    echo "  RETRY: Push blocked — git pre-push hooks cannot update in-flight refs."
    # A remote branch still on an old main is an ancestor of the rebased
    # HEAD, so a plain push fast-forwards; only rewritten commits need force.
    if git -C "$repo_root" rev-parse "origin/$branch" >/dev/null 2>&1 \
        && ! git -C "$repo_root" merge-base --is-ancestor "origin/$branch" HEAD 2>/dev/null; then
        echo "  Run: git push --force-with-lease"
    else
        echo "  Run: git push"
    fi
    exit 1
else
    git -C "$repo_root" rebase --abort 2>/dev/null || true
    echo ""
    echo "BLOCKED: Branch is behind origin/main and auto-rebase failed (conflicts)."
    echo "  Rebase manually: git fetch origin main && git rebase origin/main"
    exit 1
fi
