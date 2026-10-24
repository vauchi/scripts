#!/usr/bin/env bash
# SPDX-FileCopyrightText: 2026 Mattia Egloff <mattia.egloff@pm.me>
# SPDX-License-Identifier: GPL-3.0-or-later

set -euo pipefail
script_dir=$(cd "$(dirname "$0")" && pwd)
counter=${1:-$script_dir/../test-code-ratio.sh}
fixture=$(mktemp -d)
trap 'rm -rf "$fixture"' EXIT
crate="$fixture/fixture"
mkdir -p "$crate/src" "$crate/tests"

assert_counts() {
    local expected=$1 actual
    if ! actual=$(bash "$counter" "$crate"); then
        echo "FAIL: counter rejected a valid crate: $expected" >&2
        exit 1
    fi
    actual=$(printf '%s\n' "$actual" | awk '{$1=$1; print}')
    if [[ "$actual" != "$expected" ]]; then
        printf 'FAIL: expected <%s>, got <%s>\n' "$expected" "$actual" >&2
        exit 1
    fi
}

# A crate with external tests must not need an inline #[test] marker.
printf '// comment\npub fn value() -> u8 { 7 }\n' > "$crate/src/lib.rs"
printf '#[test]\nfn value_is_seven() { assert_eq!(fixture::value(), 7); }\n' > "$crate/tests/value.rs"
assert_counts 'fixture src= 1 test= 2 inline_tests= 0 ratio=200.0%'

# Empty/comment-only files contribute zero instead of aborting the count.
printf '  // comment\n\t\n' > "$crate/src/empty.rs"
printf '  // comment\n\t\n' > "$crate/tests/empty.rs"
assert_counts 'fixture src= 1 test= 2 inline_tests= 0 ratio=200.0%'

printf '#[test]\nfn inline() {}\n' >> "$crate/src/lib.rs"
assert_counts 'fixture src= 3 test= 2 inline_tests= 1 ratio=66.7%'

printf '// comment only\n' > "$crate/src/lib.rs"
printf '// comment only\n' > "$crate/tests/value.rs"
assert_counts 'fixture src= 0 test= 0 inline_tests= 0 ratio=N/A'
echo 'PASS: test ratio counts external tests and zero-match files'
