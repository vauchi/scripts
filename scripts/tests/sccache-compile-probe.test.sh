#!/usr/bin/env bash
# SPDX-FileCopyrightText: 2026 Mattia Egloff <mattia.egloff@pm.me>
# SPDX-License-Identifier: GPL-3.0-or-later

set -euo pipefail
SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

awk '
    /# sccache-compile-probe:/ { on=1 }
    on && /^      / { sub(/^      /, ""); print; next }
    on { exit }
' "$SCRIPT_DIR/../../ci-templates/rust-base.yml" > "$WORK/probe.sh"
[ -s "$WORK/probe.sh" ] || { echo 'FAIL: compile liveness probe missing'; exit 1; }
mkdir -p "$WORK/bin"
cat > "$WORK/bin/sccache" <<'SH'
#!/bin/sh
printf '%s\n' "$*" >> "$CALLS"
exit 0
SH
cat > "$WORK/bin/timeout" <<'SH'
#!/bin/sh
[ "$1" = --kill-after=5s ] && [ "$2" = 30s ] || exit 99
shift 2
[ "$MODE" != stalled ] || exit 124
"$@"
SH
cat > "$WORK/bin/rustup" <<'SH'
#!/bin/sh
[ "$*" = 'which rustc' ] || exit 99
printf '/test-toolchain/rustc\n'
SH
chmod +x "$WORK/bin/"*

run_probe() {
    : > "$WORK/calls"
    # shellcheck disable=SC2016 # The child shell reads the exported wrapper.
    env PATH="$WORK/bin:$PATH" MODE="$1" CALLS="$WORK/calls" \
        RUSTC_WRAPPER=sccache CI_JOB_ID=12345 \
        bash -eo pipefail -c '. "$1"; printf "WRAPPER=%s\n" "$RUSTC_WRAPPER"; printf "required checks still run\n"' \
        probe "$WORK/probe.sh" > "$WORK/out" 2>&1
}

run_probe healthy
grep -Fx 'WRAPPER=sccache' "$WORK/out"
grep -F '/test-toolchain/rustc --crate-name vauchi_cache_probe_12345' "$WORK/calls"
grep -Fx 'required checks still run' "$WORK/out"

run_probe stalled
grep -Fx 'WRAPPER=' "$WORK/out"
grep -F 'WARNING: sccache compile probe failed' "$WORK/out"
grep -Fx 'required checks still run' "$WORK/out"
[ ! -s "$WORK/calls" ]

printf 'ok — healthy cache retained; stalled compilation falls back without skipping work\n'
