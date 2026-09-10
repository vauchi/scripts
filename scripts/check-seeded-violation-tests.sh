#!/usr/bin/env bash
# SPDX-FileCopyrightText: 2026 Mattia Egloff <mattia.egloff@pm.me>
#
# SPDX-License-Identifier: GPL-3.0-or-later
#
# CC-27 enforcement for the gate layer itself: every check-*.sh under
# hooks/, scripts/ and scripts/ci/ has a paired scripts/tests/<name>*.test.sh
# that seeds its canonical violation. A check that cannot be shown to go
# red is indistinguishable from a dead one.
#
# Ratchet: scripts/.seeded-violation-baseline lists the grandfathered
# unpaired checks. New unpaired checks fail; a baselined check that gains
# a test must be removed from the baseline (fail until pruned); a baseline
# entry whose script is gone is a dead entry (fail).
#
# Usage: check-seeded-violation-tests.sh [repo-root]
# Rule page: _private/docs/lint-errors/cc27-prove-it-can-fail.md

set -u

ROOT="${1:-$(cd "$(dirname "$0")/.." && pwd)}"
BASELINE="$ROOT/scripts/.seeded-violation-baseline"
TESTS_DIR="$ROOT/scripts/tests"
PAGE="_private/docs/lint-errors/cc27-prove-it-can-fail.md"

has_test() { # $1 = basename without .sh
    for t in "$TESTS_DIR/$1"*.test.sh; do
        [ -e "$t" ] && return 0
    done
    return 1
}

in_baseline() { # $1 = repo-relative path
    [ -f "$BASELINE" ] && grep -qxF "$1" "$BASELINE"
}

errors=0
grandfathered=0

for dir in hooks scripts scripts/ci; do
    for f in "$ROOT/$dir"/check-*.sh; do
        [ -e "$f" ] || continue
        case "$f" in *.test.sh) continue ;; esac
        rel="$dir/$(basename "$f")"
        name="$(basename "$f" .sh)"
        if has_test "$name"; then
            if in_baseline "$rel"; then
                echo "  CC-27: $rel now has a test but is still in the baseline — fix: remove its line from scripts/.seeded-violation-baseline so the ratchet only tightens. [$PAGE]"
                errors=$((errors + 1))
            fi
        elif in_baseline "$rel"; then
            grandfathered=$((grandfathered + 1))
            echo "  WARN: $rel has no seeded-violation test (grandfathered in baseline)"
        else
            echo "  CC-27: $rel has no seeded-violation test — fix: add scripts/tests/$name.test.sh that seeds the violation and asserts the check goes red. [$PAGE]"
            errors=$((errors + 1))
        fi
    done
done

if [ -f "$BASELINE" ]; then
    while IFS= read -r entry; do
        [ -n "$entry" ] || continue
        case "$entry" in \#*) continue ;; esac
        if [ ! -e "$ROOT/$entry" ]; then
            echo "  CC-27: baseline lists $entry but the script does not exist — fix: remove the dead line from scripts/.seeded-violation-baseline. [$PAGE]"
            errors=$((errors + 1))
        fi
    done < "$BASELINE"
fi

if [ "$errors" -gt 0 ]; then
    echo ""
    echo "FAILED: $errors seeded-violation issue(s); $grandfathered grandfathered."
    exit 1
fi
echo "  Seeded-violation tests OK ($grandfathered grandfathered, ratchet only tightens)"
exit 0
