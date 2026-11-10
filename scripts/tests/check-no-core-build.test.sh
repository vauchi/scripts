#!/usr/bin/env bash
# SPDX-FileCopyrightText: 2026 Mattia Egloff <mattia.egloff@pm.me>
#
# SPDX-License-Identifier: GPL-3.0-or-later
#
# Sentinel suite for check-no-core-build.sh (VCI01, ADR-025): a binding
# repo's CI must not build a Core crate. Each case builds a throwaway repo;
# a build fails unless the baseline lists that exact command (CC-27).

set -u

SCRIPT="$(cd "$(dirname "$0")/.." && pwd)/check-no-core-build.sh"

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

# A repo named $2 whose .gitlab-ci.yml has the given script line.
make_repo() {
    root="$(mktemp -d)"
    mkdir -p "$root/$1"
    printf 'job:\n  script:\n    - %s\n' "$2" > "$root/$1/.gitlab-ci.yml"
    printf '%s/%s' "$root" "$1"
}
EMPTY="$(mktemp)"
rc() { "$SCRIPT" "$1" "$2" >/dev/null 2>&1; printf '%s' "$?"; }
says() { "$SCRIPT" "$1" "$2" 2>&1 | grep -c -- "$3"; }

repo=$(make_repo android './gradlew test')
assert_eq "a repo that builds no Core crate passes" "0" "$(rc "$repo" "$EMPTY")"

for line in 'cargo build -p vauchi-platform --release' \
    'cargo build --release -p vauchi-cabi --features secure-storage' \
    'cargo ndk -t aarch64-linux-android build -p vauchi-platform --release' \
    'cargo test --package vauchi-core'; do
    repo=$(make_repo android "$line")
    assert_eq "'$line' fails" "1" "$(rc "$repo" "$EMPTY")"
    assert_eq "it names ADR-025 for '$line'" "1" "$(says "$repo" "$EMPTY" "ADR-025")"
done

repo=$(make_repo android 'cargo clean -p vauchi-platform')
assert_eq "cleaning is not building" "0" "$(rc "$repo" "$EMPTY")"

repo=$(make_repo qt-display 'cargo build -p qt-display-sys')
assert_eq "building the repo's own wrapper crate passes" "0" "$(rc "$repo" "$EMPTY")"

BASELINE="$(mktemp)"
printf 'linux-qt .gitlab-ci.yml cargo build --release -p vauchi-cabi\n' > "$BASELINE"
repo=$(make_repo linux-qt 'cargo build --release -p vauchi-cabi')
assert_eq "a build the baseline lists passes" "0" "$(rc "$repo" "$BASELINE")"

repo=$(make_repo android 'cargo build --release -p vauchi-cabi')
assert_eq "the baseline is per repository" "1" "$(rc "$repo" "$BASELINE")"

# ADR-078 renames linux-qt to qt-display and linux-gtk to gtk-display
# (private#1029); the baseline keeps the names it was written with.
repo=$(make_repo qt-display 'cargo build --release -p vauchi-cabi')
assert_eq "qt-display is checked against linux-qt's baseline" "0" "$(rc "$repo" "$BASELINE")"
assert_eq "it reports under the name the baseline uses" "1" "$(says "$repo" "$BASELINE" "linux-qt builds no Core crate")"

repo=$(make_repo gtk-display 'cargo build --release -p vauchi-cabi')
assert_eq "gtk-display does not inherit linux-qt's baseline" "1" "$(rc "$repo" "$BASELINE")"

root="$(mktemp -d)"; mkdir -p "$root/linux-qt"
printf 'a:\n  script:\n    - cargo build --release -p vauchi-cabi\nb:\n  script:\n    - cargo build --release -p vauchi-cabi\n' \
    > "$root/linux-qt/.gitlab-ci.yml"
assert_eq "a second copy of a listed build fails (shrink-only)" "1" "$(rc "$root/linux-qt" "$BASELINE")"

root="$(mktemp -d)"; mkdir -p "$root/android/ci"
printf 'x:\n  script:\n    - ./gradlew test\n' > "$root/android/.gitlab-ci.yml"
printf 'y:\n  script:\n    - cargo build -p vauchi-core\n' > "$root/android/ci/native.yml"
assert_eq "an included ci/*.yml is scanned too" "1" "$(rc "$root/android" "$EMPTY")"

assert_eq "a missing repository fails rather than passing" "1" "$(rc /nonexistent/android "$EMPTY")"

printf '\n%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
