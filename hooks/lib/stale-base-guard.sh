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
# Usage: stale-base-guard.sh <repo_root>   (pre-push specs on stdin)
#   stdin: git pre-push feed, one "<lref> <lsha> <rref> <rsha>" per ref.
# Exit:  0 = proceed with the push, 1 = push blocked.

set -u

repo_root="${1:?repo root required}"
# Consumed so the caller can pipe the pre-push specs in; the ref-aware
# gate that uses them is added in a follow-up commit.
push_specs="$(cat)"
: "${push_specs}"

branch="$(git -C "$repo_root" rev-parse --abbrev-ref HEAD 2>/dev/null || true)"

if [ -n "$branch" ] && [ "$branch" != "main" ]; then
    # Self-healing: unshallow if needed, then a normal fetch. Never use
    # --depth on local dev repos — it progressively cuts history.
    if git -C "$repo_root" rev-parse --is-shallow-repository 2>/dev/null | grep -q true; then
        git -C "$repo_root" fetch --unshallow origin main --quiet 2>/dev/null \
            || git -C "$repo_root" fetch origin main --quiet 2>/dev/null || true
    else
        git -C "$repo_root" fetch origin main --quiet 2>/dev/null || true
    fi
    origin_main="$(git -C "$repo_root" rev-parse origin/main 2>/dev/null || true)"
    if [ -n "$origin_main" ]; then
        merge_base="$(git -C "$repo_root" merge-base HEAD "$origin_main" 2>/dev/null || true)"
        if [ -n "$merge_base" ] && [ "$merge_base" != "$origin_main" ]; then
            behind="$(git -C "$repo_root" rev-list --count "$merge_base".."$origin_main" 2>/dev/null || echo '?')"
            echo ""
            echo "  Branch is ${behind} commit(s) behind origin/main — rebasing..."
            if git -C "$repo_root" rebase origin/main --quiet 2>/dev/null; then
                echo "  Rebased successfully."
                echo ""
                echo "  RETRY: Push blocked — git pre-push hooks cannot update in-flight refs."
                if git -C "$repo_root" rev-parse "origin/$branch" >/dev/null 2>&1; then
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
        fi
    fi
fi

exit 0
