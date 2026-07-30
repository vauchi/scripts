#!/usr/bin/env bash
# SPDX-FileCopyrightText: 2026 Mattia Egloff <mattia.egloff@pm.me>
# SPDX-License-Identifier: GPL-3.0-or-later

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
SCRIPT="$SCRIPT_DIR/../check-component-parser-parity.py"
TEMPLATE="$SCRIPT_DIR/../../ci-templates/parser-parity.yml"
ROOT=$(mktemp -d)
trap 'rm -rf "$ROOT"' EXIT

enum="$ROOT/component.rs"
parser="$ROOT/ComponentRenderer.cs"

write_enum() {
    name="${1:-}"
    {
        printf 'pub enum Component {\n'
        printf '    Text { value: String },\n'
        printf '    Divider,\n'
        if [ -n "$name" ]; then
            printf '    %s,\n' "$name"
        fi
        printf '}\n'
    } >"$enum"
}

write_parser() {
    extra="${1:-}"
    {
        printf '"Text" => render(),\n'
        printf '"Divider" => render(),\n'
        if [ -n "$extra" ]; then
            printf '"%s" => render(),\n' "$extra"
        fi
    } >"$parser"
}

run_check() {
    protocol="${1:-component}"
    python3 "$SCRIPT" --protocol "$protocol" --frontend windows --enum-file "$enum" --parser-file "$parser" \
        >/dev/null 2>&1
}

pass=0
fail=0

expect_rc() {
    name="$1"
    want="$2"
    protocol="${3:-component}"
    set +e
    run_check "$protocol"
    got=$?
    set -e
    if [ "$got" -eq "$want" ]; then
        printf '  PASS %s\n' "$name"
        pass=$((pass + 1))
    else
        printf '  FAIL %s: wanted rc %s, got %s\n' "$name" "$want" "$got" >&2
        fail=$((fail + 1))
    fi
}

write_enum
write_parser
expect_rc 'exact current parser passes' 0

write_parser
printf '%s\n' 'pub enum Component {' '    Text { value: String },' \
    '    Divider,' '    Slider { value: i32 },' '}' >"$enum"
expect_rc 'missing current variant fails' 1

write_enum
write_parser ConfirmationDialog
expect_rc 'retired parser variant fails' 1

write_enum ShowToast
write_parser ShowToast
expect_rc 'retired core variant fails' 1

printf '%s\n' 'pub enum PresentationNode {' '    Text { value: String },' \
    '    Divider,' '}' >"$enum"
write_parser
expect_rc 'presentation protocol parser passes' 0 presentation

if grep -Fq -- '- "${PARSER_FILE}"' "$TEMPLATE"; then
    printf '  FAIL parser-parity MR job is skipped for parser directories\n' >&2
    fail=$((fail + 1))
else
    printf '  PASS parser-parity MR job runs for parser directories\n'
    pass=$((pass + 1))
fi

printf '\n%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
