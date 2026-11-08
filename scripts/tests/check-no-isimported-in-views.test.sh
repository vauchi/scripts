#!/usr/bin/env bash
# SPDX-FileCopyrightText: 2026 Mattia Egloff <mattia.egloff@pm.me>
# SPDX-License-Identifier: GPL-3.0-or-later

set -u

SCRIPT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
SCRIPT="$SCRIPT_DIR/check-no-isimported-in-views.sh"
task_guard_root="$(mktemp -d)"
trap 'rm -rf "$task_guard_root"' EXIT
mkdir -p "$task_guard_root/workspace/ios/Vauchi/Views" "$task_guard_root/bin"
view="$task_guard_root/workspace/ios/Vauchi/Views/Contact.swift"
passed=0
failed=0

assert_eq() {
    if [ "$2" = "$3" ]; then
        passed=$((passed + 1))
        printf '  PASS %s\n' "$1"
    else
        failed=$((failed + 1))
        printf '  FAIL %s: want %s, got %s\n' "$1" "$2" "$3" >&2
    fi
}

printf 'let title = "Alice"\n' > "$view"
out="$(bash "$SCRIPT" "$task_guard_root/workspace" 2>&1)"; rc=$?
assert_eq 'clean existing view tree succeeds' 0 "$rc"
assert_eq 'completed clean scan reports OK' 1 \
    "$(printf '%s\n' "$out" | grep -q '^OK:' && echo 1 || echo 0)"

printf 'if contact.isImported { }\n' > "$view"
out="$(bash "$SCRIPT" "$task_guard_root/workspace" 2>&1)"; rc=$?
assert_eq 'real forbidden member access fails' 1 "$rc"
assert_eq 'violation identifies the source file' 1 \
    "$(printf '%s\n' "$out" | grep -q 'Contact.swift:1:' && echo 1 || echo 0)"

# A present search command can fail before returning any matches.
cat > "$task_guard_root/bin/rg" <<'STUB'
#!/bin/sh
echo 'injected ripgrep failure' >&2
exit 2
STUB
chmod +x "$task_guard_root/bin/rg"
out="$(PATH="$task_guard_root/bin:$PATH" bash "$SCRIPT" "$task_guard_root/workspace" 2>&1)"; rc=$?
assert_eq 'search failure propagates its status' 2 "$rc"
assert_eq 'incomplete scan never reports OK' 0 \
    "$(printf '%s\n' "$out" | grep -q '^OK:' && echo 1 || echo 0)"
assert_eq 'search failure remains visible' 1 \
    "$(printf '%s\n' "$out" | grep -q 'injected ripgrep failure' && echo 1 || echo 0)"

printf '\n%d passed, %d failed\n' "$passed" "$failed"
[ "$failed" -eq 0 ]
