#!/usr/bin/env bash
# SPDX-FileCopyrightText: 2026 Mattia Egloff <mattia.egloff@pm.me>
#
# SPDX-License-Identifier: GPL-3.0-or-later

# socratic-review.sh — cross-provider Socratic review of a branch diff.
#
# Usage: socratic-review.sh <repo_dir> [codex|kimi|both]
# Example: socratic-review.sh core
#          socratic-review.sh _private kimi
#
# Sends `origin/main...HEAD` to non-Claude reviewers (Codex, Kimi) with a
# Socratic brief: interrogate the change, do not rewrite it. The point is
# provider diversity — a Claude session reviewing its own diff with Claude
# is an echo chamber, and the failure mode is agreement, not error. Same
# rationale as the `rodin` agent, applied to code.
#
# Advisory only: questions are not a gate, so a reviewer that raises
# hard questions still exits 0. A reviewer that fails to *run* exits 1 —
# a missing CLI must fail loud, never be skipped silently.

set -euo pipefail

REPO_DIR=${1:-}
WHICH=${2:-both}
MAX_DIFF_BYTES=${SOCRATIC_MAX_DIFF_BYTES:-200000}

if [[ -z "$REPO_DIR" ]]; then
    echo "Usage: socratic-review.sh <repo_dir> [codex|kimi|both]" >&2
    exit 2
fi
if [[ ! -d "$REPO_DIR/.git" ]]; then
    echo "ERROR: not a git repo: $REPO_DIR" >&2
    exit 2
fi
case "$WHICH" in
    codex|kimi|both) ;;
    *) echo "ERROR: reviewer must be codex, kimi, or both (got '$WHICH')" >&2; exit 2 ;;
esac

BRANCH=$(git -C "$REPO_DIR" rev-parse --abbrev-ref HEAD)
if [[ "$BRANCH" == "main" ]]; then
    echo "ERROR: on main — nothing to review. Switch to a feature branch." >&2
    exit 2
fi

if ! git -C "$REPO_DIR" rev-parse --verify --quiet origin/main >/dev/null; then
    echo "ERROR: origin/main missing in $REPO_DIR — run \`just git fetch\` first." >&2
    exit 2
fi

DIFF=$(git -C "$REPO_DIR" diff origin/main...HEAD)
if [[ -z "$DIFF" ]]; then
    echo "ERROR: no changes on $BRANCH vs origin/main — nothing to review." >&2
    exit 2
fi

# Bounded input, loudly. A silently truncated diff reads as "the reviewer
# saw everything" when it did not — the reviewer's blind spot has to be
# visible to whoever reads the questions.
DIFF_BYTES=$(printf '%s' "$DIFF" | wc -c | tr -d ' ')
TRUNCATED=""
if [[ "$DIFF_BYTES" -gt "$MAX_DIFF_BYTES" ]]; then
    DIFF=$(printf '%s' "$DIFF" | head -c "$MAX_DIFF_BYTES")
    TRUNCATED="yes"
fi

SUBJECTS=$(git -C "$REPO_DIR" log origin/main..HEAD --reverse --format='- %s')

BRIEF="You are a Socratic reviewer. Interrogate this change; do not rewrite it.

Rules:
- Output ONLY questions, as a numbered list of at most 8.
- Ask what would expose a wrong assumption, an unhandled edge, an
  unstated tradeoff, or a claim the diff asserts but does not
  demonstrate.
- Prefer questions that cannot be answered from the diff alone.
- Where a question implies a concrete risk, name that risk in one clause.
- No praise. No summary of what the diff does. No verdict. No patches.
- If the change looks sound, ask harder questions rather than approving.

Commits on this branch:
$SUBJECTS

Diff (git diff origin/main...HEAD):
$DIFF"

if [[ -n "$TRUNCATED" ]]; then
    BRIEF="$BRIEF

NOTE: this diff was truncated at ${MAX_DIFF_BYTES} of ${DIFF_BYTES} bytes.
Say so if a question depends on the part you cannot see."
fi

run_reviewer() {
    name="$1"; out="$2"
    case "$name" in
        codex) codex exec "$BRIEF" >"$out" 2>&1 ;;
        kimi)  kimi -p "$BRIEF" >"$out" 2>&1 ;;
    esac
}

REVIEWERS=""
case "$WHICH" in
    both) REVIEWERS="codex kimi" ;;
    *)    REVIEWERS="$WHICH" ;;
esac

for r in $REVIEWERS; do
    if ! command -v "$r" >/dev/null 2>&1; then
        echo "ERROR: '$r' not on PATH — install it or pass a single reviewer." >&2
        exit 1
    fi
done

WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

echo "=== Socratic review: $(basename "$REPO_DIR") @ $BRANCH ==="
echo "  diff: ${DIFF_BYTES} bytes$([ -n "$TRUNCATED" ] && printf ' (TRUNCATED to %s)' "$MAX_DIFF_BYTES")"
echo "  reviewers: $REVIEWERS"
if [[ -n "$TRUNCATED" ]]; then
    echo "  WARNING: reviewers saw only the first ${MAX_DIFF_BYTES} of ${DIFF_BYTES} bytes."
    echo "           Raise SOCRATIC_MAX_DIFF_BYTES or review in smaller branches."
fi
echo ""

# Both providers are network round-trips; run them concurrently.
PIDS=""
for r in $REVIEWERS; do
    ( cd "$REPO_DIR" && run_reviewer "$r" "$WORK/$r.out" ) &
    PIDS="$PIDS $!:$r"
done

FAILED=0
for entry in $PIDS; do
    pid=${entry%%:*}
    name=${entry##*:}
    if ! wait "$pid"; then
        FAILED=1
        echo "ERROR: $name failed to run — output below." >&2
    fi
done

for r in $REVIEWERS; do
    echo "───────────── $r ─────────────"
    if [[ -s "$WORK/$r.out" ]]; then
        cat "$WORK/$r.out"
    else
        echo "(no output)"
    fi
    echo ""
done

if [[ "$FAILED" -ne 0 ]]; then
    exit 1
fi
echo "Advisory only — questions are not a gate. Answer them or record why not."
