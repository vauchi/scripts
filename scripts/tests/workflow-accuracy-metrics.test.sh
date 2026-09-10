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
    # 6 commits, 2 feat, 3 fix → fix/feat 1.50; ledger 3 entries → 50.0 per 100

    mkdir -p "$ws/_private/docs/problems/done" "$ws/_private/scripts"
    cat > "$ws/_private/docs/intervention-ledger.md" <<'EOF'
# ledger
- 2026-09-01 | gate | lt5m | retry | mechanical | `style` | a
- 2026-09-02 | gate | lt5m | review | prevented-defect | `stale-state` | b
- 2026-09-03 | other | 5-30m | retry | prevented-defect | `unverified-claim` | c
EOF
    for d in 2026-08-01-a 2026-08-02-b 2026-08-03-c; do
        mkdir -p "$ws/_private/docs/problems/$d"
        printf '| **Status** | implementing |\n' > "$ws/_private/docs/problems/$d/README.md"
    done
    for d in 2026-08-04-d 2026-08-05-e 2026-08-06-f; do
        mkdir -p "$ws/_private/docs/problems/done/$d"
        printf '| **Status** | done |\n| **Last Updated** | 2026-09-01 |\n' \
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
assert_eq "ledger per 100 commits = 50.0" "1" \
    "$(printf '%s' "$out" | grep -qE 'ledger entries per 100 commits[^0-9]+50\.0' && echo 1 || echo 0)"
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
