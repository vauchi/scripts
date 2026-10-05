#!/usr/bin/env bash
# SPDX-FileCopyrightText: 2026 Mattia Egloff <mattia.egloff@pm.me>
#
# SPDX-License-Identifier: GPL-3.0-or-later

# Sentinel suite for ci/mutation-progress.sh. The monitor watches a
# cargo-mutants process it did not start: in CI the job shell is the
# parent and the monitor a sibling, so `wait` is not available to it
# (vauchi/private#487). Each case starts the watched process from this
# shell, as the job does, and the monitor must still report and exit 0.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
SCRIPT="$SCRIPT_DIR/../ci/mutation-progress.sh"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

export MUTATION_PROGRESS_POLL_SECS=0.1

pass=0
fail=0

assert_eq() {
    name="$1"; want="$2"; got="$3"
    if [ "$want" = "$got" ]; then
        printf '  PASS %s\n' "$name"
        pass=$((pass + 1))
    else
        printf '  FAIL %s\n    want: %s\n    got:  %s\n' "$name" "$want" "$got" >&2
        fail=$((fail + 1))
    fi
}

assert_contains() {
    name="$1"; needle="$2"; haystack="$3"
    case "$haystack" in
        *"$needle"*)
            printf '  PASS %s\n' "$name"
            pass=$((pass + 1))
            ;;
        *)
            printf '  FAIL %s\n    missing: %s\n    in: %s\n' "$name" "$needle" "$haystack" >&2
            fail=$((fail + 1))
            ;;
    esac
}

# Plays a cargo-mutants run into $1: discovery, then the listed outcomes,
# then exits with $2. Started in the background from this shell, so the
# monitor sees a process that is not its child; the pid lands in $pid.
fake_mutants() {
    out="$1"; exit_with="$2"; shift 2
    (
        sleep 0.2
        echo '[{"a":1},{"b":2},{"c":3}]' > "$out/mutants.json"
        for outcome in "$@"; do
            sleep 0.2
            echo "src/lib.rs: $outcome mutant" >> "$out/$outcome.txt"
        done
        sleep 0.2
        exit "$exit_with"
    ) &
    pid=$!
}

run_monitor() {
    set +e
    output="$("$SCRIPT" "$1" "$2" 2>&1)"
    status=$?
    set -e
}

# ── 1. Watched process fails (missed mutants): monitor still exits 0 ──
mkdir -p "$WORK/missed"
fake_mutants "$WORK/missed" 2 caught missed caught
run_monitor "$pid" "$WORK/missed"
wait "$pid" && mutants_status=0 || mutants_status=$?
assert_eq "cargo-mutants itself reports failure to its parent" 2 "$mutants_status"
assert_eq "monitor exits 0 whatever the watched process returned" 0 "$status"
assert_contains "summary counts the caught mutants" "Caught:" "$output"
assert_contains "summary lists the missed mutant" "src/lib.rs: missed mutant" "$output"
case "$output" in
    *"not a child"*) assert_eq "monitor never waits on a process it did not start" "" "not a child" ;;
    *) assert_eq "monitor never waits on a process it did not start" "" "" ;;
esac

# ── 2. Clean run: exit 0 and no missed section ───────────────────────
mkdir -p "$WORK/clean"
fake_mutants "$WORK/clean" 0 caught unviable
run_monitor "$pid" "$WORK/clean"
wait "$pid" || true
assert_eq "clean run exits 0" 0 "$status"
assert_contains "clean run reports testing section" "Testing 3 mutants" "$output"
case "$output" in
    *"Missed mutants:"*) assert_eq "clean run has no missed section" "" "Missed mutants:" ;;
    *) assert_eq "clean run has no missed section" "" "" ;;
esac

# ── 3. Process dies before discovery: monitor exits 0, not 127 ───────
mkdir -p "$WORK/early"
( sleep 0.1; exit 101 ) &
pid=$!
run_monitor "$pid" "$WORK/early"
wait "$pid" || true
assert_eq "early death exits 0" 0 "$status"
assert_contains "early death still prints a summary" "Total:    0 / 0" "$output"

# ── 5. A find without -printf (BSD, BusyBox) still gets a summary ────
# GNU-only flags made the monitor die after its first progress line on
# macOS, before the summary (vauchi/private#521). This find refuses
# -printf the way BSD and BusyBox find do, on any host.
mkdir -p "$WORK/bin" "$WORK/bsd"
cat > "$WORK/bin/find" <<'FIND'
#!/usr/bin/env bash
for a in "$@"; do
    if [ "$a" = "-printf" ]; then
        echo "find: -printf: unknown primary or operator" >&2
        exit 1
    fi
done
exec /usr/bin/find "$@"
FIND
chmod +x "$WORK/bin/find"
fake_mutants "$WORK/bsd" 2 caught missed
PATH="$WORK/bin:$PATH" run_monitor "$pid" "$WORK/bsd"
wait "$pid" || true
assert_eq "without -printf the monitor still exits 0" 0 "$status"
assert_contains "without -printf the summary still counts" "Total:    2 / 3" "$output"

# ── 4. The template, as parent, waits for cargo-mutants itself ───────
TEMPLATE="$SCRIPT_DIR/../../ci-templates/mutation.yml"
template_body="$(cat "$TEMPLATE")"
# The needle is the literal line of shell the template must contain.
# shellcheck disable=SC2016
assert_contains "template waits on MUTANTS_PID after the monitor returns" \
    'wait "$MUTANTS_PID" && MUTATION_EXIT=0 || MUTATION_EXIT=$?' "$template_body"

printf '\n%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
