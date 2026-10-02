#!/usr/bin/env bash
# SPDX-FileCopyrightText: 2026 Mattia Egloff <mattia.egloff@pm.me>
#
# SPDX-License-Identifier: GPL-3.0-or-later

# Sentinel suite for check-image-pins.sh. Each case builds a tiny
# workspace with Dockerfiles and answers the registry through
# CHECK_IMAGE_PINS_RESOLVER, so the check is shown to FAIL on a stale pin
# and on an untracked one, not only to pass (CC-27).

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
SCRIPT="$SCRIPT_DIR/../check-image-pins.sh"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

PINNED="sha256:$(printf 'a%.0s' $(seq 1 64))"
NEWER="sha256:$(printf 'b%.0s' $(seq 1 64))"

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

# A resolver that answers every tag with the digest in $WORK/answer, or
# fails like an unreachable registry when the file holds "down".
cat > "$WORK/resolver" <<'RESOLVER'
#!/bin/sh
answer=$(cat "$(dirname "$0")/answer")
if [ "$answer" = "down" ]; then
    echo "manifest of $1: HTTP 000" >&2
    exit 1
fi
printf '%s\n' "$answer"
RESOLVER
chmod +x "$WORK/resolver"

# Builds workspace $1 with one repo whose Dockerfile body is $2.
workspace_with() {
    mkdir -p "$WORK/$1/svc"
    printf '%s\n' "$2" > "$WORK/$1/svc/Dockerfile"
}

run_check() {
    set +e
    output="$(CHECK_IMAGE_PINS_RESOLVER="$WORK/resolver" "$SCRIPT" "$WORK/$1" 2>&1)"
    status=$?
    set -e
}

TRACKED="FROM rust:1.93 AS builder
# pin-tracks: example.test/base:latest
FROM example.test/base@$PINNED"

# ── 1. The tag still points at the pinned digest → OK, exit 0 ────────
workspace_with current "$TRACKED"
printf '%s\n' "$PINNED" > "$WORK/answer"
run_check current
assert_eq "current pin exits 0" 0 "$status"
assert_contains "current pin is reported OK" "OK         svc/Dockerfile — example.test/base:latest" "$output"

# ── 2. The tag moved on → STALE, exit 1, names both digests ──────────
printf '%s\n' "$NEWER" > "$WORK/answer"
run_check current
assert_eq "stale pin exits 1" 1 "$status"
assert_contains "stale pin names the new digest" "now points at $NEWER, pinned $PINNED" "$output"

# ── 3. Registry unreachable → UNVERIFIED, exit 2, not stale ──────────
printf 'down\n' > "$WORK/answer"
run_check current
assert_eq "unreachable registry exits 2" 2 "$status"
assert_contains "unreachable registry is reported unverified" "UNVERIFIED svc/Dockerfile — example.test/base:latest (manifest of example.test/base:latest: HTTP 000)" "$output"

# ── 4. Digest pin with no pin-tracks line → UNTRACKED, exit 1 ────────
workspace_with untracked "FROM example.test/base@$PINNED"
printf '%s\n' "$PINNED" > "$WORK/answer"
run_check untracked
assert_eq "untracked pin exits 1" 1 "$status"
assert_contains "untracked pin is named" "UNTRACKED  svc/Dockerfile" "$output"

# ── 5. Only tag-pinned images → nothing to check, exit 0 ─────────────
workspace_with tags_only "FROM rust:1.93-trixie AS builder"
run_check tags_only
assert_eq "no digest pins exits 0" 0 "$status"
assert_contains "no digest pins says so" "no digest-pinned base images found" "$output"

printf '\n%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
