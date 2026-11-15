#!/usr/bin/env bash
# SPDX-FileCopyrightText: 2026 Mattia Egloff <mattia.egloff@pm.me>
#
# SPDX-License-Identifier: GPL-3.0-or-later

# Sentinel suite for the job script in ci-templates/mutation.yml. The
# block is extracted from the template and run the way GitLab runs it,
# under `bash -eo pipefail`, with a fake `cargo mutants` on PATH. It must
# exit with cargo-mutants' own status and hand the result directory to
# the metrics push (vauchi/private#511).

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
TEMPLATE="$SCRIPT_DIR/../../ci-templates/mutation.yml"
PROGRESS="$SCRIPT_DIR/../ci/mutation-progress.sh"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

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

# The job's run block: from the line that sets PROGRESS_SCRIPT to the end
# of that YAML literal, de-indented.
awk '
    /PROGRESS_SCRIPT="\$\(pwd\)\/mutation-progress.sh"/ { on = 1 }
    on && /^      / { sub(/^      /, ""); print; next }
    on && /^$/ { print; next }
    on { exit }
' "$TEMPLATE" > "$WORK/job.sh"

mkdir -p "$WORK/bin"
# cargo mutants stand-in: writes the files cargo-mutants writes under
# --output, then exits with $FAKE_MUTANTS_EXIT.
cat > "$WORK/bin/cargo" <<'FAKE'
#!/usr/bin/env bash
printf '%s\n' "$@" > "${FAKE_MUTANTS_ARGS:-/dev/null}"
out=""
while [ $# -gt 0 ]; do
    if [ "$1" = "--output" ]; then out="$2"; fi
    shift
done
mkdir -p "$out/mutants.out"
echo '[{"a":1},{"b":2}]' > "$out/mutants.out/mutants.json"
echo "src/lib.rs:1:1: replace a" > "$out/mutants.out/caught.txt"
if [ "${FAKE_MUTANTS_EXIT:-0}" -ne 0 ]; then
    echo "src/lib.rs:2:1: replace b" > "$out/mutants.out/missed.txt"
fi
sleep 0.3
exit "${FAKE_MUTANTS_EXIT:-0}"
FAKE
chmod +x "$WORK/bin/cargo"

run_job() {
    rm -rf "$WORK/run" && mkdir -p "$WORK/run/repo"
    cp "$PROGRESS" "$WORK/run/mutation-progress.sh"
    cat > "$WORK/run/push-mutation.sh" <<'PUSH'
#!/usr/bin/env bash
ls "$1" > "$(dirname "$0")/pushed-dir-listing"
PUSH
    chmod +x "$WORK/run/push-mutation.sh"
    set +e
    (
        cd "$WORK/run" || exit 99
        PATH="$WORK/bin:$PATH" FAKE_MUTANTS_EXIT="$1" \
            MUTATION_WORKDIR=repo MUTATION_TEST_TOOL=nextest MUTATION_PACKAGE='' \
            MUTATION_EXTRA_FLAGS="${MUTATION_EXTRA_FLAGS:-}" MUTATION_TIMEOUT_NIGHTLY=60 CI_PROJECT_NAME=demo \
            MUTATION_PROGRESS_POLL_SECS=0.1 MUTATION_SHARDS="${MUTATION_SHARDS:-1}" \
            FAKE_MUTANTS_ARGS="$WORK/run/args" \
            bash -eo pipefail "$WORK/job.sh"
    ) > "$WORK/run/output" 2>&1
    status=$?
    set -e
}

assert_eq "the job block was found in the template" "yes" \
    "$(grep -q 'cargo mutants' "$WORK/job.sh" && echo yes || echo no)"

# ── 1. Nothing missed: the job passes ────────────────────────────────
run_job 0
assert_eq "a clean run exits 0" 0 "$status"
assert_eq "the metrics push sees the result files" "yes" \
    "$(grep -q '^caught.txt$' "$WORK/run/pushed-dir-listing" && echo yes || echo no)"
assert_eq "the summary counts the caught mutant" "yes" \
    "$(grep -q 'Total: *1 / 2' "$WORK/run/output" && echo yes || echo no)"

assert_eq "one shard (the default) passes no --shard flag" "no" \
    "$(grep -q -- '--shard' "$WORK/run/args" && echo yes || echo no)"

# ── 2. Missed mutants: the job fails with cargo-mutants' status ──────
run_job 2
assert_eq "missed mutants exit with cargo-mutants' status" 2 "$status"

# ── 3. Generated shards retain the existing day-of-year selection ────
MUTATION_SHARDS=3 run_job 0
assert_eq "a sharded run exits 0" 0 "$status"
assert_eq "three shards pass today's slice as --shard k/3" \
    "$(( 10#$(date -u +%j) % 3 ))/3" \
    "$(awk '/^--shard$/ { getline; print }' "$WORK/run/args")"

MUTATION_SHARDS=80 MUTATION_EXTRA_FLAGS='--jobs 8 --shard 64/80 --sharding round-robin' run_job 0
assert_eq "an explicit shard run exits 0" 0 "$status"
assert_eq "an explicit shard is the only shard option" 1 \
    "$(grep -c '^--shard$' "$WORK/run/args")"
assert_eq "the consumer's explicit shard is retained" '64/80' \
    "$(awk '/^--shard$/ { getline; print }' "$WORK/run/args")"
assert_eq "round-robin remains the consumer's selected algorithm" 'round-robin' \
    "$(awk '/^--sharding$/ { getline; print }' "$WORK/run/args")"

MUTATION_SHARDS=80 MUTATION_EXTRA_FLAGS='--shard=64/80' run_job 0
assert_eq "an equal-form explicit shard run exits 0" 0 "$status"
assert_eq "the equal-form shard is retained" 1 \
    "$(grep -c '^--shard=64/80$' "$WORK/run/args")"
assert_eq "the template adds no shard beside the equal form" 0 \
    "$(grep -c '^--shard$' "$WORK/run/args" || true)"

run_job 4
assert_eq "a baseline failure retains cargo-mutants status" 4 "$status"
run_job 1
assert_eq "a usage failure retains cargo-mutants status" 1 "$status"

printf '\n%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
