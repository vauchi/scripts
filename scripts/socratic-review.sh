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
# `.git` is a *file* in linked worktrees and submodules, so test for a
# working repo rather than for a directory.
if ! git -C "$REPO_DIR" rev-parse --git-dir >/dev/null 2>&1; then
    echo "ERROR: not a git repo: $REPO_DIR" >&2
    exit 2
fi
case "$MAX_DIFF_BYTES" in
    ''|*[!0-9]*|0)
        echo "ERROR: SOCRATIC_MAX_DIFF_BYTES must be a positive integer (got '$MAX_DIFF_BYTES')" >&2
        exit 2
        ;;
esac
case "$WHICH" in
    codex|kimi|both) ;;
    *) echo "ERROR: reviewer must be codex, kimi, or both (got '$WHICH')" >&2; exit 2 ;;
esac

# Linux caps a SINGLE argv entry at MAX_ARG_STRLEN (32 * PAGE_SIZE = 131072
# bytes), independently of the far larger ARG_MAX that `getconf ARG_MAX`
# reports. The brief is one argument, so a diff near that size aborted with
# "Argument list too long" instead of being reviewed — observed 2026-08-04 at
# 131205 bytes, only 133 over the line. The default cap of 200000 sat ABOVE
# the ceiling, which made the failure reachable by default and made the
# script's own advice ("Raise SOCRATIC_MAX_DIFF_BYTES") actively wrong.
#
# codex reads the prompt from stdin (`codex exec … -`), so it is unaffected
# and keeps the full cap. kimi's `-p` takes an argument and has no stdin
# mode, so whenever kimi reviews, the brief must fit in one argument. The
# margin below the ceiling covers the brief's own prose and the commit
# subject list, which share that same argument.
ARGV_CEILING=110000
CLAMPED=""
if [[ "$WHICH" != "codex" && "$MAX_DIFF_BYTES" -gt "$ARGV_CEILING" ]]; then
    MAX_DIFF_BYTES=$ARGV_CEILING
    CLAMPED="yes"
fi

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
#
# The trailing `sed '$d'` drops the final line after the byte cut. A byte
# cap can land mid-character in a UTF-8 diff, and half a code point is
# both an unreadable hunk and invalid input to the provider; dropping the
# partial line is cheaper than counting characters.
#
# Truncation reads from a temp file, never `printf "$DIFF" | head -c`:
# `head` exits at the cap while `printf` is still writing, and past the
# 64K pipe buffer that SIGPIPE plus `pipefail` aborts the whole script —
# precisely on the large diffs truncation exists to serve.
DIFF_BYTES=$(printf '%s' "$DIFF" | wc -c | tr -d ' ')
TRUNCATED=""
if [[ "$DIFF_BYTES" -gt "$MAX_DIFF_BYTES" ]]; then
    TMP_DIFF=$(mktemp)
    printf '%s' "$DIFF" > "$TMP_DIFF"
    DIFF=$(head -c "$MAX_DIFF_BYTES" "$TMP_DIFF" | sed '$d')
    rm -f "$TMP_DIFF"
    TRUNCATED="yes"
    if [[ -z "$DIFF" ]]; then
        echo "ERROR: SOCRATIC_MAX_DIFF_BYTES=$MAX_DIFF_BYTES is too small to hold one diff line." >&2
        exit 2
    fi
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

# A hung provider must not hold the branch hostage; `timeout` is absent on
# some BSD hosts, so it is used when present rather than required.
TIMEOUT_SECS=${SOCRATIC_TIMEOUT:-600}
GUARD=()
if command -v timeout >/dev/null 2>&1; then
    GUARD=(timeout "$TIMEOUT_SECS")
fi

# `${GUARD[@]+...}` rather than a bare `"${GUARD[@]}"`: expanding an empty
# array under `set -u` is an error on bash 3.2, which is what macOS ships.
run_reviewer() {
    name="$1"; out="$2"
    case "$name" in
        # `-o` writes the final message only — without it codex echoes the
        # entire brief back and buries the questions in it.
        # The brief goes in on STDIN, not argv. `-` is codex's documented
        # "read the prompt from stdin" form, and it is what keeps a large
        # diff from hitting MAX_ARG_STRLEN — see the ARGV_CEILING note above.
        codex)
            if printf '%s' "$BRIEF" \
                | ${GUARD[@]+"${GUARD[@]}"} codex exec -o "$out" - \
                >/dev/null 2>"$out.err"; then
                return 0
            fi
            cat "$out.err" >>"$out"
            return 1
            ;;
        kimi)
            ${GUARD[@]+"${GUARD[@]}"} kimi -p "$BRIEF" >"$out" 2>&1
            ;;
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
PIDS=""
# Killing the children matters on Ctrl-C: provider calls are long, and an
# abandoned one keeps burning a paid request after the caller walked away.
cleanup() {
    for entry in $PIDS; do
        kill "${entry%%:*}" 2>/dev/null || true
    done
    rm -rf "$WORK"
}
trap cleanup EXIT INT TERM

echo "=== Socratic review: $(basename "$REPO_DIR") @ $BRANCH ==="
echo "  diff: ${DIFF_BYTES} bytes$([ -n "$TRUNCATED" ] && printf ' (TRUNCATED to %s)' "$MAX_DIFF_BYTES")"
echo "  scope: committed changes only — the working tree is not reviewed"
echo "  reviewers: $REVIEWERS"
# The whole premise is that the reviewer did not write the code. Running
# kimi against a branch a Kimi session authored restores the echo chamber
# without any visible sign that it happened.
INVOKER=${VAUCHI_AGENT:-claude}
case " $REVIEWERS " in
    *" $INVOKER "*)
        echo "  WARNING: invoker '$INVOKER' is also a reviewer — it is reviewing its own work."
        echo "           Drop it (\`socratic-review <repo> $([ "$INVOKER" = kimi ] && echo codex || echo kimi)\`) for an independent read."
        ;;
esac
if [[ -n "$TRUNCATED" ]]; then
    echo "  WARNING: reviewers saw only the first ${MAX_DIFF_BYTES} of ${DIFF_BYTES} bytes."
    if [[ -n "$CLAMPED" ]]; then
        echo "           Cap clamped to ${ARGV_CEILING} because kimi is reviewing: its"
        echo "           prompt is one argv entry, limited to 131072 bytes by the kernel."
        echo "           Raising SOCRATIC_MAX_DIFF_BYTES will NOT help — review with"
        echo "           \`socratic-review <repo> codex\` (stdin, no limit) or split the branch."
    else
        echo "           Raise SOCRATIC_MAX_DIFF_BYTES or review in smaller branches."
    fi
fi
echo ""

# Both providers are network round-trips; run them concurrently.
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
