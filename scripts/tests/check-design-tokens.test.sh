#!/usr/bin/env bash
# SPDX-FileCopyrightText: 2026 Mattia Egloff <mattia.egloff@pm.me>
#
# SPDX-License-Identifier: GPL-3.0-or-later

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT="$SCRIPT_DIR/../check-design-tokens.sh"

pass=0
fail=0

assert_eq() {
    local name="$1" expected="$2" actual="$3"
    if [[ "$expected" == "$actual" ]]; then
        printf '  PASS %s\n' "$name"
        pass=$((pass + 1))
    else
        printf '  FAIL %s — expected %s, got %s\n' \
            "$name" "$expected" "$actual" >&2
        fail=$((fail + 1))
    fi
}

# Writes one source line into a fresh directory and prints the number of
# COLOR findings the checker reports for it.
colour_hits() {
    local file="$1" line="$2" dir
    dir="$(mktemp -d)"
    mkdir -p "$(dirname "$dir/$file")"
    printf '%s\n' "$line" >"$dir/$file"
    bash "$SCRIPT" "$dir" | grep -c '^COLOR ' || true
    rm -rf "$dir"
}

strict_exit() {
    local file="$1" line="$2" dir rc=0
    dir="$(mktemp -d)"
    printf '%s\n' "$line" >"$dir/$file"
    bash "$SCRIPT" --strict-categories=COLOR "$dir" >/dev/null 2>&1 || rc=$?
    rm -rf "$dir"
    printf '%s' "$rc"
}

echo "check-design-tokens.sh"

assert_eq "swift modifier colour counts" "1" \
    "$(colour_hits View.swift '        .foregroundColor(.red)')"
assert_eq "swift tone mapping to a named colour counts" "1" \
    "$(colour_hits Tone.swift '        case .error: .red')"
assert_eq "swift ternary between named colours counts" "1" \
    "$(colour_hits View.swift '    .foregroundColor(ok ? .green : .orange)')"
assert_eq "swift Color.name counts" "1" \
    "$(colour_hits View.swift '    .background(Color.black.opacity(0.32))')"
assert_eq "swift Color(red:green:blue:) literal counts" "1" \
    "$(colour_hits View.swift '    let c = Color(red: 0.1, green: 0.2, blue: 0.3)')"
assert_eq "swift semantic system colours do not count" "0" \
    "$(colour_hits View.swift '        case .standard: .primary')"
assert_eq "kotlin hex colour counts" "1" \
    "$(colour_hits Row.kt '    val c = Color(0xFF2E7D32)')"
assert_eq "kotlin named colour counts" "1" \
    "$(colour_hits Row.kt '    .background(Color.Black.copy(alpha = 0.34f))')"
assert_eq "kotlin transparent does not count" "0" \
    "$(colour_hits Row.kt '    .background(Color.Transparent)')"
assert_eq "a reasoned design-token-ok marker suppresses the line" "0" \
    "$(colour_hits View.swift '    Color.black // design-token-ok: camera preview is black by definition')"
assert_eq "a marker without a reason does not suppress" "1" \
    "$(colour_hits View.swift '    Color.black // design-token-ok:')"
assert_eq "the swift theme service may name fallback colours" "0" \
    "$(colour_hits Services/ThemeService.swift '        guard let theme else { return .red }')"
assert_eq "the kotlin theme definition may hold hex colours" "0" \
    "$(colour_hits ui/theme/Theme.kt '    success = Color(0xFF2E7D32),')"
assert_eq "strict COLOR fails on a kotlin colour" "1" \
    "$(strict_exit Row.kt '    val c = Color(0xFF2E7D32)')"
assert_eq "strict COLOR passes on clean code" "0" \
    "$(strict_exit Row.kt '    val c = MaterialTheme.colorScheme.error')"

printf '\n%d passed, %d failed\n' "$pass" "$fail"
[[ "$fail" -eq 0 ]]
