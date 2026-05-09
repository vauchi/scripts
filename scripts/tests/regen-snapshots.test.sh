#!/usr/bin/env bash
# SPDX-FileCopyrightText: 2026 Mattia Egloff <mattia.egloff@pm.me>
#
# SPDX-License-Identifier: GPL-3.0-or-later

# regen-snapshots.test.sh — Pins the snapshot-regen dispatcher behaviour
# for the cargo-vet auto-sync bot. Origin:
# `_private/docs/problems/2026-05-03-vet-autosync-stale-snapshots`
# Phase 2 (G1') — when an auto-sync MR's Cargo.lock bump moves
# vauchi-core to a rev that touched UI code, run the appropriate
# snapshot regen command for the host repo.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT="$SCRIPT_DIR/../ci/regen-snapshots.sh"

pass=0
fail=0

assert_eq() {
    local name="$1" want="$2" got="$3"
    if [[ "$want" == "$got" ]]; then
        printf '  PASS %s\n' "$name"
        pass=$((pass + 1))
    else
        printf '  FAIL %s\n    want: %q\n    got:  %q\n' "$name" "$want" "$got" >&2
        fail=$((fail + 1))
    fi
}

assert_status() {
    local name="$1" want="$2" got="$3"
    if [[ "$want" -eq "$got" ]]; then
        printf '  PASS %s (exit %s)\n' "$name" "$got"
        pass=$((pass + 1))
    else
        printf '  FAIL %s\n    want exit: %s\n    got exit:  %s\n' "$name" "$want" "$got" >&2
        fail=$((fail + 1))
    fi
}

# Build a temp workspace + PATH-shadow `cargo` so we can capture
# invocations without actually running cargo.
make_workspace() {
    local dir
    dir=$(mktemp -d)
    mkdir -p "$dir/bin"
    # Default `cargo` mock: log the call to $dir/cargo.log and exit 0.
    # Tests that need a different exit code overwrite this script.
    cat >"$dir/bin/cargo" <<'CARGO_MOCK'
#!/usr/bin/env bash
echo "cargo $*" >>"${CARGO_LOG:-/dev/null}"
exit "${CARGO_EXIT_CODE:-0}"
CARGO_MOCK
    chmod +x "$dir/bin/cargo"
    printf '%s' "$dir"
}

run_helper() {
    # Run the helper in a clean workspace + clean PATH (only mock cargo
    # + system bins under /usr/bin and /bin). Returns combined stdout.
    local ws="$1" old_sha="${2:-abc1234}" new_sha="${3:-def5678}"
    (
        cd "$ws"
        PATH="$ws/bin:/usr/bin:/bin" \
        CARGO_LOG="$ws/cargo.log" \
        "$SCRIPT" "$old_sha" "$new_sha" 2>&1
    )
}

# ── Case 1: no snapshot tooling → exit 0, skip message ───────────
ws=$(make_workspace)
out=$(run_helper "$ws") || rc=$?
rc=${rc:-0}
assert_status "no tooling: exit clean" 0 "$rc"
case "$out" in
    *"no snapshot tooling"*)
        printf '  PASS no tooling: skip message printed\n'
        pass=$((pass + 1))
        ;;
    *)
        printf '  FAIL no tooling: skip message missing\n    got: %q\n' "$out" >&2
        fail=$((fail + 1))
        ;;
esac
[[ ! -f "$ws/cargo.log" ]] || {
    printf '  FAIL no tooling: cargo should not have been invoked\n    log: %q\n' "$(cat "$ws/cargo.log")" >&2
    fail=$((fail + 1))
}
rm -rf "$ws"
unset rc

# ── Case 2: Cargo.toml declares insta → cargo insta test --accept ─
ws=$(make_workspace)
cat >"$ws/Cargo.toml" <<'TOML'
[package]
name = "fixture"
version = "0.0.0"

[dev-dependencies]
insta = "1"
TOML
out=$(run_helper "$ws") || rc=$?
rc=${rc:-0}
assert_status "insta dep: exit 0" 0 "$rc"
log=$(cat "$ws/cargo.log" 2>/dev/null || true)
assert_eq "insta dep: cargo invocation" "cargo insta test --accept --workspace" "$log"
rm -rf "$ws"
unset rc

# ── Case 3: *.snap files (no insta in Cargo.toml) → still dispatch ─
ws=$(make_workspace)
mkdir -p "$ws/src/snapshots"
echo "snap content" >"$ws/src/snapshots/foo.snap"
out=$(run_helper "$ws") || rc=$?
rc=${rc:-0}
assert_status "snap files only: exit 0" 0 "$rc"
log=$(cat "$ws/cargo.log" 2>/dev/null || true)
assert_eq "snap files only: cargo invocation" "cargo insta test --accept --workspace" "$log"
rm -rf "$ws"
unset rc

# ── Case 4: cargo insta fails → helper propagates non-zero ───────
ws=$(make_workspace)
cat >"$ws/Cargo.toml" <<'TOML'
[dev-dependencies]
insta = "1"
TOML
# Override cargo mock to fail with exit 17.
cat >"$ws/bin/cargo" <<'CARGO_FAIL'
#!/usr/bin/env bash
echo "cargo $*" >>"${CARGO_LOG:-/dev/null}"
exit 17
CARGO_FAIL
chmod +x "$ws/bin/cargo"
out=$(run_helper "$ws") || rc=$?
rc=${rc:-0}
assert_status "insta failure: propagates exit 17" 17 "$rc"
rm -rf "$ws"
unset rc

# ── Case 5: missing args → usage error ───────────────────────────
out=$("$SCRIPT" 2>&1) && rc=$? || rc=$?
rc=${rc:-0}
case "$out" in
    *usage*|*Usage*|*USAGE*)
        printf '  PASS missing args: usage hint printed\n'
        pass=$((pass + 1))
        ;;
    *)
        printf '  FAIL missing args: no usage hint\n    got: %q\n' "$out" >&2
        fail=$((fail + 1))
        ;;
esac
if [[ $rc -eq 0 ]]; then
    printf '  FAIL missing args: should exit non-zero\n    got exit: %s\n' "$rc" >&2
    fail=$((fail + 1))
else
    printf '  PASS missing args: exit %s\n' "$rc"
    pass=$((pass + 1))
fi
unset rc

# ── Case 6: only one arg → usage error ───────────────────────────
out=$("$SCRIPT" 'abc1234' 2>&1) && rc=$? || rc=$?
rc=${rc:-0}
if [[ $rc -eq 0 ]]; then
    printf '  FAIL one arg only: should exit non-zero\n    got exit: %s\n' "$rc" >&2
    fail=$((fail + 1))
else
    printf '  PASS one arg only: exit %s\n' "$rc"
    pass=$((pass + 1))
fi
unset rc

echo ""
echo "── ${pass} passed, ${fail} failed ──"
[[ $fail -eq 0 ]]
