#!/usr/bin/env bash
# SPDX-FileCopyrightText: 2026 Mattia Egloff <mattia.egloff@pm.me>
#
# SPDX-License-Identifier: GPL-3.0-or-later
#
# Sentinel suite for check-adr-constraints.sh: each rule passes on a clean
# core tree and fails, naming the rule, on a seeded violation (CC-27).
# Builds throwaway core trees; no dependency on the live one.

set -u

SCRIPT="$(cd "$(dirname "$0")/.." && pwd)/check-adr-constraints.sh"

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

# A core tree with one crate and a clean source file.
make_core() {
    core="$(mktemp -d)"
    mkdir -p "$core/vauchi-core/src"
    printf '[package]\nname = "vauchi-core"\n\n[dependencies]\nzeroize = "1"\n' \
        > "$core/vauchi-core/Cargo.toml"
    printf 'pub trait ProximityVerifier {}\npub struct MockProximityVerifier;\n' \
        > "$core/vauchi-core/src/lib.rs"
    printf '%s' "$core"
}
rc() { "$SCRIPT" "$1" >/dev/null 2>&1; printf '%s' "$?"; }
says() { "$SCRIPT" "$1" 2>&1 | grep -c -- "$2"; }

core=$(make_core)
assert_eq "clean tree passes" "0" "$(rc "$core")"
rm -rf "$core"

core=$(make_core)
printf 'pub trait Platform {\n    fn now(&self) -> u64;\n}\n' > "$core/vauchi-core/src/platform.rs"
assert_eq "a Platform trait fails" "1" "$(rc "$core")"
assert_eq "it names the Platform rule" "1" "$(says "$core" "no Platform trait")"
rm -rf "$core"

for crate in vauchi-hardware vauchi-linux-hw; do
    core=$(make_core)
    printf '%s = { path = "../x" }\n' "$crate" >> "$core/vauchi-core/Cargo.toml"
    assert_eq "a core dependency on $crate fails" "1" "$(rc "$core")"
    assert_eq "it names the dependency rule for $crate" "1" \
        "$(says "$core" "hardware depends on Core")"
    rm -rf "$core"
done

for item in "pub trait AccelerometerBackend: Send {}" \
    "pub struct MockBLEVerifier { d: f32 }" \
    "pub trait NfcAdapter {}"; do
    core=$(make_core)
    printf '%s\n' "$item" > "$core/vauchi-core/src/hw.rs"
    assert_eq "'$item' fails" "1" "$(rc "$core")"
    assert_eq "it names the hardware-type rule for '$item'" "1" \
        "$(says "$core" "no hardware trait or mock")"
    rm -rf "$core"
done

core=$(make_core)
mkdir -p "$core/vauchi-core/tests"
printf 'pub trait Platform {}\npub struct MockBLEVerifier;\n' \
    > "$core/vauchi-core/tests/fixture.rs"
assert_eq "test code is not production code" "0" "$(rc "$core")"
rm -rf "$core"

assert_eq "a missing directory fails rather than passing" "1" "$(rc /nonexistent/core)"

printf '\n%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
