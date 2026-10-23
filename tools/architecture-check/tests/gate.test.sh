#!/usr/bin/env bash
# SPDX-FileCopyrightText: 2026 Mattia Egloff <mattia.egloff@pm.me>
# SPDX-License-Identifier: GPL-3.0-or-later

set -euo pipefail
scripts_root=$(cd "$(dirname "$0")/../../.." && pwd)
gate="$scripts_root/scripts/architecture-check.sh"
fixture=$(mktemp -d)
trap 'rm -rf "$fixture"' EXIT
mkdir -p "$fixture/vauchi-core/src"
cat > "$fixture/.architecture-policy.json" <<'JSON'
{"schema_version":1,"crates":{"vauchi-core":1},"layers":{"vauchi-core/lib":5,"vauchi-core/domain":1,"vauchi-core/storage":4,"vauchi-core/a":1,"vauchi-core/b":1},"compatibility_modules":[],"acyclic_crates":["vauchi-core"]}
JSON
cat > "$fixture/.architecture-baseline.json" <<'JSON'
{"schema_version":1,"exceptions":{},"apis":[]}
JSON
printf 'mod domain; mod storage; mod a; mod b;\n' > "$fixture/vauchi-core/src/lib.rs"
printf 'pub struct Domain;\n' > "$fixture/vauchi-core/src/domain.rs"
printf 'pub struct Storage;\n' > "$fixture/vauchi-core/src/storage.rs"
printf 'pub struct A;\n' > "$fixture/vauchi-core/src/a.rs"
printf 'pub struct B;\n' > "$fixture/vauchi-core/src/b.rs"
git -C "$fixture" init -q -b fixture
git -C "$fixture" add .
git -C "$fixture" -c user.name=Fixture -c user.email=fixture@example.invalid commit -qm fixture

expect_status() {
    local expected=$1 actual=0
    shift
    bash "$gate" "$fixture" "$@" > "$fixture/result.log" 2>&1 || actual=$?
    if [[ "$actual" != "$expected" ]]; then
        cat "$fixture/result.log" >&2
        echo "Expected status $expected, got $actual" >&2
        exit 1
    fi
}

expect_status 0 check HEAD
printf 'use crate::storage::Storage;\n' > "$fixture/vauchi-core/src/domain.rs"
expect_status 1 check HEAD
grep -q 'VRS06' "$fixture/result.log"
printf 'pub struct Domain;\n' > "$fixture/vauchi-core/src/domain.rs"
expect_status 0 check HEAD
printf 'pub struct A; pub use crate::b::B;\n' > "$fixture/vauchi-core/src/a.rs"
printf 'pub struct B; use crate::a::A;\n' > "$fixture/vauchi-core/src/b.rs"
expect_status 1 check HEAD
grep -q 'ownership cycle: vauchi-core/a, vauchi-core/b' "$fixture/result.log"
printf 'pub struct B;\n' > "$fixture/vauchi-core/src/b.rs"
expect_status 0 check HEAD
mv "$fixture/.architecture-baseline.json" "$fixture/saved.json"
expect_status 2 check HEAD
mv "$fixture/saved.json" "$fixture/.architecture-baseline.json"
expect_status 2 check missing-base-ref
expect_status 0 advisory HEAD
echo 'Architecture wrapper: injected edge, cycle through re-export, removals and missing inputs verified.'
