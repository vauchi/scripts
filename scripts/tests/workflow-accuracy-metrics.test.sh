#!/usr/bin/env bash
# SPDX-FileCopyrightText: 2026 Mattia Egloff <mattia.egloff@pm.me>
#
# SPDX-License-Identifier: GPL-3.0-or-later
#
# Sentinel suite for scripts/workflow-accuracy-metrics.sh — the four
# numbers session-end prints so the workflow's accuracy is measured every
# session instead of once per audit: ledger entries per 100 commits,
# stale share of active records, fix/feat ratio, already-fixed closures.

set -u

SCRIPT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
SCRIPT="$SCRIPT_DIR/workflow-accuracy-metrics.sh"

pass=0
fail=0
assert_eq() {
    name="$1"; want="$2"; got="$3"
    if [ "$want" = "$got" ]; then
        pass=$((pass + 1)); printf '  PASS %s\n' "$name"
    else
        fail=$((fail + 1))
        printf '  FAIL %s\n    want: %s\n    got:  %s\n' "$name" "$want" "$got" >&2
    fi
}

commit_in() { # $1=repo $2=subject
    git -C "$1" commit -q --allow-empty -m "$2"
}

days_ago() { # $1 = days back → YYYY-MM-DD (BSD probe first: BSD date misreads -d)
    if date -v-1d >/dev/null 2>&1; then
        date -v-"$1"d +%F
    else
        date -d "$1 days ago" +%F # portable-shell-ok: GNU branch of a probed BSD/GNU switch
    fi
}

# A miniature workspace: two product repos with dated commits, a ledger,
# three active records (one stale per a stubbed checker), and three done
# records of which one closed as already fixed.
build_workspace() {
    ws="$(mktemp -d)"
    for r in core relay; do
        mkdir -p "$ws/$r"
        git -C "$ws/$r" init -q
        git -C "$ws/$r" config user.email t@example.com
        git -C "$ws/$r" config user.name t
    done
    commit_in "$ws/core" "feat: one"
    commit_in "$ws/core" "feat: two"
    commit_in "$ws/core" "fix: three"
    commit_in "$ws/core" "fix: four"
    commit_in "$ws/relay" "fix: five"
    commit_in "$ws/relay" "docs: six"
    # 6 commits, 2 feat, 3 fix → fix/feat 1.50; ledger 4 entries → 66.7 per 100

    mkdir -p "$ws/_private/docs/problems/done" "$ws/_private/scripts"
    # Dated relative to today: fixed dates slid out of the 30-day window and
    # turned this suite red on 2026-10-01.
    recent="$(days_ago 5)"
    cat > "$ws/_private/docs/intervention-ledger.md" <<EOF
# ledger
- $recent | gate | lt5m | retry | mechanical | \`style\` | a
- $recent | gate | lt5m | review | prevented-defect | \`stale-state\`
- $recent | other | 5-30m | retry | prevented-defect | \`unverified-claim\` | c
- $recent | gate | gt30m | wait | mechanical | six fields, before classes
EOF
    # Minutes by bucket midpoint: 3 + 3 + 17 + 45 = 68 → 1133 per 100 commits.
    # The second entry has a class and no note; the fourth predates classes.
    for d in 2026-08-01-a 2026-08-02-b 2026-08-03-c; do
        mkdir -p "$ws/_private/docs/problems/$d"
        printf '| **Status** | implementing |\n' > "$ws/_private/docs/problems/$d/README.md"
    done
    for d in 2026-08-04-d 2026-08-05-e 2026-08-06-f; do
        mkdir -p "$ws/_private/docs/problems/done/$d"
        printf '| **Status** | done |\n| **Last Updated** | %s |\n' "$recent" \
            > "$ws/_private/docs/problems/done/$d/README.md"
    done
    printf 'Closed: already fixed by core!1\n' >> "$ws/_private/docs/problems/done/2026-08-04-d/README.md"
    # Stubbed checker: one stale record out of three active.
    cat > "$ws/_private/scripts/check-problem-records.py" <<'EOF'
print("  [WARN] docs/problems/2026-08-01-a/README.md: stale implementing record (40 days since last commit, threshold 30)")
print("RESULT: PASS (with warnings)")
EOF
    echo "$ws"
}

WS="$(build_workspace)"
out="$("$SCRIPT" --root "$WS" --days 30 2>&1)"; rc=$?

assert_eq "runs clean: exit 0" "0" "$rc"
assert_eq "ledger per 100 commits = 66.7" "1" \
    "$(printf '%s' "$out" | grep -qE 'ledger entries per 100 commits[^0-9]+66\.7' && echo 1 || echo 0)"
assert_eq "ledger minutes per 100 commits, by class, largest first" \
    "  ledger minutes per 100 commits: 1133 (unclassified 750, unverified-claim 283, stale-state 50, style 50)" \
    "$(printf '%s\n' "$out" | grep 'ledger minutes')"
assert_eq "stale share = 1/3" "1" \
    "$(printf '%s' "$out" | grep -qE 'stale active records[^0-9]+1/3' && echo 1 || echo 0)"
assert_eq "fix/feat ratio = 1.50" "1" \
    "$(printf '%s' "$out" | grep -qE 'fix/feat ratio[^0-9]+1\.50' && echo 1 || echo 0)"
assert_eq "already-fixed closures = 1/3" "1" \
    "$(printf '%s' "$out" | grep -qE 'closed as already fixed[^0-9]+1/3' && echo 1 || echo 0)"

# ── zero commits must not divide by zero ──────────────────────────────
out="$("$SCRIPT" --root "$WS" --days 0 2>&1)"; rc=$?
assert_eq "empty window: exit 0" "0" "$rc"
assert_eq "empty window: n/a instead of division error" "1" \
    "$(printf '%s' "$out" | grep -q 'n/a' && echo 1 || echo 0)"

# ── missing ledger is reported, not fatal ─────────────────────────────
rm "$WS/_private/docs/intervention-ledger.md"
out="$("$SCRIPT" --root "$WS" --days 30 2>&1)"; rc=$?
assert_eq "missing ledger: exit 0" "0" "$rc"
assert_eq "missing ledger: says so" "1" \
    "$(printf '%s' "$out" | grep -qi 'no ledger' && echo 1 || echo 0)"

rm -rf "$WS"

# ── VPR13: assumption to evidence, where wrongness is found, criteria
#    before a spike (private#1012) — read from _private's git history ──
record_commit() { # $1=repo $2=record dir $3=ISO date $4=README content
    mkdir -p "$1/docs/problems/$2"
    printf '%s\n' "$4" > "$1/docs/problems/$2/README.md"
    git -C "$1" add -A
    GIT_AUTHOR_DATE="$3" GIT_COMMITTER_DATE="$3" git -C "$1" commit -q -m "$2 $3"
}

V="$(mktemp -d)"
P="$V/_private"
mkdir -p "$P/scripts"
git -C "$P" init -q
git -C "$P" config user.email t@example.com
git -C "$P" config user.name t
known='## Knowns
- the restart clears it — assumed: last time; refuted if: it sticks again'
# a: assumption on day 0, evidence on day 4
record_commit "$P" 2026-11-01-a 2026-11-01T10:00:00Z "| **Status** | planning |
$known"
record_commit "$P" 2026-11-01-a 2026-11-05T10:00:00Z "| **Status** | testing |
$known
## Evidence
- before/after"
# b: assumption, no evidence yet
record_commit "$P" 2026-11-01-b 2026-11-02T10:00:00Z "| **Status** | implementing |
$known"
# c: implementation refuted the assumption and sent the record back
record_commit "$P" 2026-11-01-c 2026-11-02T10:00:00Z "| **Status** | implementing |
$known"
record_commit "$P" 2026-11-01-c 2026-11-03T10:00:00Z "| **Status** | investigating |
$known"
# d: the strongest alternative won before any code
record_commit "$P" 2026-11-01-d 2026-11-02T10:00:00Z "| **Status** | planning |
$known
## Strongest Alternative
Re-register — adopted: the restart left it stuck"
# e: criteria committed a day before the spike report
record_commit "$P" 2026-11-01-e 2026-11-02T10:00:00Z "| **Status** | planning |
$known
## Selection Criteria
- three green pipelines"
record_commit "$P" 2026-11-01-e 2026-11-03T10:00:00Z "| **Status** | planning |
$known
## Selection Criteria
- three green pipelines
## Strongest Alternative
Re-register — spiked: spike/1-b, two green"
# f: criteria written in the same commit as the spike report
record_commit "$P" 2026-11-01-f 2026-11-02T10:00:00Z "| **Status** | planning |
$known
## Selection Criteria
- three green pipelines
## Strongest Alternative
Re-register — spiked: spike/2-b, two green"
# g: the markers named in prose, outside Strongest Alternative, count for nothing
record_commit "$P" 2026-11-01-g 2026-11-02T10:00:00Z "| **Status** | planning |
| **Next slice** | check that criteria predate a spiked: report; count adopted: ones |
$known"
printf 'print("RESULT: PASS")\n' > "$P/scripts/check-problem-records.py"

out="$("$SCRIPT" --root "$V" --days 30 2>&1)"; rc=$?
assert_eq "vpr13 workspace: exit 0" "0" "$rc"
assert_eq "assumption to evidence: median days over records that reached evidence" \
    "  assumption to evidence: median 4d (1 of 7 refuted-if records have evidence)" \
    "$(printf '%s\n' "$out" | grep 'assumption to evidence')"
assert_eq "wrongness found: at the alternative and in implementation" \
    "  wrongness found: 1 at the alternative (adopted:), 1 in implementation (back to investigating)" \
    "$(printf '%s\n' "$out" | grep 'wrongness found')"
assert_eq "spikes with criteria committed first: same-commit criteria do not count" \
    "  spikes with criteria committed first: 1/2" \
    "$(printf '%s\n' "$out" | grep 'spikes with criteria')"
rm -rf "$V"

# ── the live workspace runs (numbers vary; shape must not) ────────────
LIVE="$(cd "$SCRIPT_DIR/../.." && pwd)"
if [ -f "$LIVE/_private/docs/intervention-ledger.md" ]; then
    out="$("$SCRIPT" --root "$LIVE" --days 30 2>&1)"; rc=$?
    assert_eq "live workspace: exit 0" "0" "$rc"
    assert_eq "live workspace: four metric lines" "4" \
        "$(printf '%s\n' "$out" | grep -cE '^  (ledger entries|stale active|fix/feat|closed as)')"
fi

printf '\n%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
