#!/usr/bin/env bash
# SPDX-FileCopyrightText: 2026 Mattia Egloff <mattia.egloff@pm.me>
#
# SPDX-License-Identifier: GPL-3.0-or-later
#
# The four numbers that say whether the problem→code workflow is getting
# more accurate. Printed by `just session-end` so the trend is visible
# every session instead of once per audit (the 2026-08-21 ledger analysis
# was the only run in seven weeks). Evidence base and targets:
# _private/docs/problems/2026-07-21-process-meta-churn-ratio/
#
#   ledger entries per 100 commits   maintainer interruptions per unit of work
#     (+ minutes per 100 commits)    the same, weighted by time, by defect class
#   stale active records             WIP that nobody touched in 30 days
#   fix/feat ratio                   rework per feature
#   closed as already fixed          intake that never verified against code
#
# and three for VPR13's planning gate (private#1012), over all records:
#
#   assumption to evidence           days from a Knowns 'refuted if:' to ## Evidence
#   wrongness found                  alternatives adopted vs records sent back
#   spikes with criteria first       ## Selection Criteria committed before 'spiked:'
#
# Usage: workflow-accuracy-metrics.sh [--root DIR] [--days N]

set -u

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
DAYS=30
while [ $# -gt 0 ]; do
    case "$1" in
        --root) ROOT="$2"; shift 2 ;;
        --days) DAYS="$2"; shift 2 ;;
        *) echo "unknown argument: $1" >&2; exit 2 ;;
    esac
done

PRIVATE="$ROOT/_private"
LEDGER="$PRIVATE/docs/intervention-ledger.md"
PROBLEMS="$PRIVATE/docs/problems"
CHECKER="$PRIVATE/scripts/check-problem-records.py"

cutoff_date() { # $1 = days back → YYYY-MM-DD (BSD probe first: BSD date misreads -d)
    if date -v-1d >/dev/null 2>&1; then
        date -v-"$1"d +%F
    else
        date -d "$1 days ago" +%F # portable-shell-ok: GNU branch of a probed BSD/GNU switch
    fi
}

ratio() { # $1 numerator $2 denominator $3 decimals $4 scale
    awk -v n="$1" -v d="$2" -v p="$3" -v s="$4" 'BEGIN { printf "%.*f", p, (n / d) * s }'
}

commits=0; feats=0; fixes=0
if [ "$DAYS" -gt 0 ]; then
    for repo in "$ROOT"/*/; do
        [ -d "$repo/.git" ] || continue
        subjects="$(git -C "$repo" log --no-merges --since="$DAYS days ago" --format=%s 2>/dev/null)"
        [ -n "$subjects" ] || continue
        commits=$((commits + $(printf '%s\n' "$subjects" | grep -c .)))
        feats=$((feats + $(printf '%s\n' "$subjects" | grep -c '^feat')))
        fixes=$((fixes + $(printf '%s\n' "$subjects" | grep -c '^fix')))
    done
fi

echo "── workflow accuracy (last ${DAYS}d) ──"

if [ ! -f "$LEDGER" ]; then
    echo "  ledger entries per 100 commits: n/a (no ledger file at $LEDGER)"
elif [ "$commits" -eq 0 ]; then
    echo "  ledger entries per 100 commits: n/a (0 commits in window)"
else
    since="$(cutoff_date "$DAYS")"
    entries=$(awk -v w="$since" '/^- 20[0-9][0-9]-[0-9][0-9]-[0-9][0-9] \|/ { if ($2 >= w) n++ } END { print n + 0 }' "$LEDGER")
    echo "  ledger entries per 100 commits: $(ratio "$entries" "$commits" 1 100) ($entries entries / $commits commits)"
    # Counts rank the many short interruptions first; the time sits in the few
    # long ones (private#466). Bucket midpoints, gt30m capped at 45, so every
    # figure is a lower bound — the weights of the 2026-08-21 ledger analysis.
    awk -F' [|] ' -v w="$since" -v c="$commits" '
        /^- 20[0-9][0-9]-[0-9][0-9]-[0-9][0-9] \|/ {
            if (substr($1, 3) < w) next
            class = ($6 ~ /^`[a-z-]+` *$/) ? $6 : "unclassified"
            gsub(/`| /, "", class)
            minutes = ($3 == "lt5m") ? 3 : ($3 == "5-30m") ? 17 : 45
            by[class] += minutes; total += minutes
        }
        END {
            if (!total) exit
            printf "  ledger minutes per 100 commits: %.0f (", total * 100 / c
            sep = ""
            while (1) {
                top = ""
                for (k in by) if (top == "" || by[k] > by[top] || (by[k] == by[top] && k < top)) top = k
                if (top == "") break
                printf "%s%s %.0f", sep, top, by[top] * 100 / c
                delete by[top]; sep = ", "
            }
            print ")"
        }' "$LEDGER"
fi

active=0
for d in "$PROBLEMS"/[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]-*/; do
    [ -f "$d/README.md" ] && active=$((active + 1))
done
if [ -f "$CHECKER" ] && [ "$active" -gt 0 ]; then
    stale=$( (cd "$PRIVATE" && python3 "$CHECKER" 2>/dev/null) | grep -c 'stale [a-z]* record')
    echo "  stale active records: $stale/$active ($(ratio "$stale" "$active" 0 100)%)"
else
    echo "  stale active records: n/a (no checker or no active records)"
fi

if [ "$feats" -eq 0 ]; then
    echo "  fix/feat ratio: n/a ($fixes fix / 0 feat)"
else
    echo "  fix/feat ratio: $(ratio "$fixes" "$feats" 2 1) ($fixes fix / $feats feat)"
fi

done_touched=0; done_already=0
if [ "$DAYS" -gt 0 ] && [ -d "$PROBLEMS/done" ]; then
    since="$(cutoff_date "$DAYS")"
    for r in "$PROBLEMS"/done/*/README.md; do
        [ -f "$r" ] || continue
        updated=$(grep -oE '\*\*Last Updated\*\*[^0-9]*[0-9]{4}-[0-9]{2}-[0-9]{2}' "$r" | grep -oE '[0-9]{4}-[0-9]{2}-[0-9]{2}$' | head -1)
        [ -n "$updated" ] && [ "$updated" \> "$since" ] || continue
        done_touched=$((done_touched + 1))
        if grep -qiE 'already (fixed|merged|resolved|implemented|landed)|superseded|duplicate of' "$r"; then
            done_already=$((done_already + 1))
        fi
    done
fi
if [ "$done_touched" -eq 0 ]; then
    echo "  closed as already fixed/duplicate: n/a (no done records touched in window)"
else
    echo "  closed as already fixed/duplicate: $done_already/$done_touched of done records touched in window"
fi

# VPR13 (private#1012): how fast a plan's assumption meets evidence, and
# where wrongness is found. Read from git history, not the window: the
# rule is recent and its records are few.
first_commit_time() { # $1 = record path relative to _private, $2 = string
    git -C "$PRIVATE" log --reverse --format=%ct -S"$2" -- "$1" 2>/dev/null | head -1
}

section() { # $1 = README, $2 = heading word: that ## section's body
    awk -v h="$2" '/^## / { inside = (index($0, "## " h) == 1); next } inside' "$1"
}

refuted=0; with_evidence=0; adopted=0; reopened=0; spiked=0; criteria_first=0; gaps=""
while IFS= read -r r; do
    [ -n "$r" ] || continue
    section "$r" Knowns | grep -qiE 'refuted if *:' || continue
    rel="${r#"$PRIVATE"/}"
    refuted=$((refuted + 1))
    alternative="$(section "$r" 'Strongest Alternative')"
    assumed="$(first_commit_time "$rel" 'refuted if')"
    evidenced="$(first_commit_time "$rel" '## Evidence')"
    if [ -n "$assumed" ] && [ -n "$evidenced" ]; then
        with_evidence=$((with_evidence + 1))
        gaps="$gaps $(( (evidenced - assumed) / 86400 ))"
    fi
    printf '%s\n' "$alternative" | grep -qiE 'adopted *:' && adopted=$((adopted + 1))
    # A commit that turns a planning/planned/implementing Status into investigating.
    if git -C "$PRIVATE" log -p --format='@@commit %h' -- "$rel" 2>/dev/null | awk '
        /^@@commit / { if (from && to) found = 1; from = 0; to = 0; next }
        /^-.*\*\*Status\*\*.*(planning|planned|implementing)/ { from = 1 }
        /^\+.*\*\*Status\*\*.*investigating/ { to = 1 }
        END { if (from && to) found = 1; exit !found }'; then
        reopened=$((reopened + 1))
    fi
    if printf '%s\n' "$alternative" | grep -qiE 'spiked *:'; then
        spiked=$((spiked + 1))
        criteria="$(first_commit_time "$rel" '## Selection Criteria')"
        report="$(first_commit_time "$rel" 'spiked:')"
        [ -n "$criteria" ] && [ -n "$report" ] && [ "$criteria" -lt "$report" ] \
            && criteria_first=$((criteria_first + 1))
    fi
done <<EOF
$(find "$PROBLEMS" -name README.md 2>/dev/null)
EOF

if [ "$refuted" -eq 0 ]; then
    echo "  assumption to evidence: n/a (no refuted-if records)"
elif [ "$with_evidence" -eq 0 ]; then
    echo "  assumption to evidence: n/a (0 of $refuted refuted-if records have evidence)"
else
    median="$(printf '%s' "$gaps" | tr ' ' '\n' | grep . | sort -n | awk '{ v[NR] = $1 } END { m = (NR % 2) ? v[(NR + 1) / 2] : (v[NR / 2] + v[NR / 2 + 1]) / 2; printf "%g", m }')"
    echo "  assumption to evidence: median ${median}d ($with_evidence of $refuted refuted-if records have evidence)"
fi
echo "  wrongness found: $adopted at the alternative (adopted:), $reopened in implementation (back to investigating)"
if [ "$spiked" -eq 0 ]; then
    echo "  spikes with criteria committed first: n/a (no spiked alternatives)"
else
    echo "  spikes with criteria committed first: $criteria_first/$spiked"
fi
exit 0
