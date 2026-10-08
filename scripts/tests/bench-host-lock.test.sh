#!/usr/bin/env bash
# SPDX-FileCopyrightText: 2026 Mattia Egloff <mattia.egloff@pm.me>
#
# SPDX-License-Identifier: GPL-3.0-or-later

# Sentinel suite for the host-wide CPU lock (vauchi/private#554). Every
# self-hosted job holds it shared (ci-templates/rust-base.yml, .self-hosted);
# a benchmark measures under it exclusively (ci-templates/benchmark.yml,
# .bench-host-exclusive), so criterion never samples beside another repo's
# build on the same runner host. Both blocks are extracted from the
# templates and run as GitLab runs them, under `bash -eo pipefail`, with
# real flock(1) and a scratch HOME.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
TEMPLATES="$SCRIPT_DIR/../../ci-templates"
WORK="$(mktemp -d)"
trap 'kill $(jobs -p) 2>/dev/null || true; rm -rf "$WORK"' EXIT

command -v flock >/dev/null 2>&1 || { echo "SKIP: no flock(1) on this host"; exit 77; }

pass=0
fail=0

ok() {
    printf '  PASS %s\n' "$1"
    pass=$((pass + 1))
}

nok() {
    printf '  FAIL %s\n' "$1" >&2
    fail=$((fail + 1))
}

# The YAML literal that starts with the given marker comment, de-indented.
extract() {
    awk -v marker="$1" '
        index($0, marker) { on = 1 }
        on && /^      / { sub(/^      /, ""); print; next }
        on && /^$/ { print; next }
        on { exit }
    ' "$2"
}

extract "# host-cpu-lock: entry" "$TEMPLATES/rust-base.yml" > "$WORK/entry.sh"
extract "# host-cpu-lock: exclusive" "$TEMPLATES/benchmark.yml" > "$WORK/exclusive.sh"
[ -s "$WORK/entry.sh" ] || { echo "FAIL: no entry block in rust-base.yml" >&2; exit 1; }
[ -s "$WORK/exclusive.sh" ] || { echo "FAIL: no exclusive block in benchmark.yml" >&2; exit 1; }

export HOME="$WORK/home"
mkdir -p "$HOME"

# A job: take the entry lock, write when it got in, hold it for $2 seconds.
job() {
    bash -eo pipefail -c ". '$WORK/entry.sh'; now() { python3 -c \"import time; print(time.time())\"; }; now > '$1'; sleep $2"
}

# A benchmark: take the entry lock (it is a self-hosted job too), then the
# exclusive lock, write when it got it, measure for $2 seconds.
bench() {
    BENCH_LOCK_WAIT="${3:-30}" bash -eo pipefail -c \
        ". '$WORK/entry.sh'; . '$WORK/exclusive.sh'; now() { python3 -c \"import time; print(time.time())\"; }; now > '$1'; sleep $2"
}

later() { awk -v a="$1" -v b="$2" 'BEGIN { exit !(a >= b) }'; }

# Wait (up to 20s) until a path matching the glob exists.
await() {
    for _ in $(seq 1 100); do
        for f in $1; do [ -e "$f" ] && return 0; done
        sleep 0.2
    done
    return 1
}

echo "bench-host-lock:"

# 1. A benchmark waits for a running job to finish before it measures.
job "$WORK/j1.in" 2 &
jpid=$!
sleep 0.3
bench "$WORK/b1.in" 0 > "$WORK/b1.out" 2>&1
wait "$jpid"
jend=$(awk '{ printf "%.3f\n", $1 + 2 }' "$WORK/j1.in")
if later "$(cat "$WORK/b1.in")" "$jend"; then
    ok "a benchmark measures only after the running job has finished"
else
    nok "a benchmark measured while another job held the host"
fi

# 2. A job that arrives while a benchmark measures waits until it is done.
bench "$WORK/b2.in" 2 > "$WORK/b2.out" 2>&1 &
bpid=$!
await "$WORK/b2.in"
job "$WORK/j2.in" 0
wait "$bpid"
bend=$(awk '{ printf "%.3f\n", $1 + 2 }' "$WORK/b2.in")
if later "$(cat "$WORK/j2.in")" "$bend"; then
    ok "a job arriving during a measurement waits for it"
else
    nok "a job started while a benchmark was measuring"
fi

# 3. A job that arrives while a benchmark waits for the host also waits:
#    a steady stream of jobs must not starve the benchmark.
job "$WORK/j3a.in" 2 &
j3a=$!
sleep 0.3
bench "$WORK/b3.in" 1 > "$WORK/b3.out" 2>&1 &
b3=$!
await "$HOME/.cache/vauchi-ci-locks/gate.*"
job "$WORK/j3b.in" 0
wait "$j3a" "$b3"
if later "$(cat "$WORK/j3b.in")" "$(cat "$WORK/b3.in")"; then
    ok "a job arriving while a benchmark waits goes after it"
else
    nok "a later job overtook the waiting benchmark"
fi

# 4. The wait is bounded: past BENCH_LOCK_WAIT the benchmark measures
#    anyway and says so, rather than hold the gate for the job's lifetime.
job "$WORK/j4.in" 5 &
j4=$!
sleep 0.3
rc=0
bench "$WORK/b4.in" 0 1 > "$WORK/b4.out" 2>&1 || rc=$?
kill "$j4" 2>/dev/null || true
wait "$j4" 2>/dev/null || true
if [ "$rc" -eq 0 ] && grep -q "WARNING" "$WORK/b4.out" && ! later "$(cat "$WORK/b4.in")" "$(awk '{ printf "%.3f\n", $1 + 5 }' "$WORK/j4.in")"; then
    ok "past BENCH_LOCK_WAIT the benchmark measures anyway with a warning"
else
    nok "the bounded wait did not give up with a warning (rc=$rc): $(cat "$WORK/b4.out")"
fi

# 5. Without flock(1) (nell, macOS) both blocks are no-ops.
mkdir -p "$WORK/nobin"
rc=0
PATH="$WORK/nobin" BENCH_LOCK_WAIT=1 /bin/bash -eo pipefail -c \
    ". '$WORK/entry.sh'; . '$WORK/exclusive.sh'" > "$WORK/b5.out" 2>&1 || rc=$?
if [ "$rc" -eq 0 ]; then
    ok "without flock both blocks pass through"
else
    nok "without flock a block failed (rc=$rc): $(cat "$WORK/b5.out")"
fi

echo "bench-host-lock: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
