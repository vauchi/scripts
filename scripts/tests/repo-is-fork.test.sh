#!/usr/bin/env bash
# SPDX-FileCopyrightText: 2026 Mattia Egloff <mattia.egloff@pm.me>
# SPDX-License-Identifier: GPL-3.0-or-later
# A forked library keeps upstream's licensing layout, so the pre-push
# REUSE gate skips a repo that repos.toml marks `fork = true`
# (vauchi/private#1314). Any doubt about the registry keeps the gate on.
set -uo pipefail
DIR="$(cd "$(dirname "$0")/../.." && pwd)"
HELPER="$DIR/hooks/lib/repo-is-fork.sh"
HOOK="$DIR/hooks/pre-push"
PASS=0
FAIL=0

check() {
    local name="$1"
    shift
    if "$@"; then
        PASS=$((PASS + 1))
    else
        FAIL=$((FAIL + 1))
        echo "FAIL: $name" >&2
    fi
}

is_fork() { bash "$HELPER" "$1" >/dev/null 2>&1; }
is_not_fork() { ! is_fork "$1"; }

WS=$(mktemp -d)
OUTSIDE=$(mktemp -d)
trap 'rm -rf "$WS" "$OUTSIDE"' EXIT
mkdir -p "$WS/scripts/scripts/lib" "$WS/utils/forklib" "$WS/utils/unlisted" \
    "$WS/ownlib" "$WS/other/forklib" "$OUTSIDE/forklib"
cp "$DIR/scripts/lib/repo-registry.py" "$WS/scripts/scripts/lib/"
cat >"$WS/repos.toml" <<'EOF'
[[repo]]
name = "forklib"
path = "utils/forklib"
fork = true

[[repo]]
name = "ownlib"
path = "ownlib"
EOF

check "a repo marked fork = true is a fork" is_fork "$WS/utils/forklib"
check "a repo without the flag is not a fork" is_not_fork "$WS/ownlib"
check "a repo missing from repos.toml is not a fork" is_not_fork "$WS/utils/unlisted"
check "the flag belongs to the registered path, not the directory name" is_not_fork "$WS/other/forklib"
check "a checkout outside any workspace is not a fork" is_not_fork "$OUTSIDE/forklib"

printf '[[repo]\nname = "forklib"\n' >"$WS/repos.toml"
check "an unreadable repos.toml keeps the gate on" is_not_fork "$WS/utils/forklib"

printf '[[repo]]\nname = "forklib"\npath = "utils/forklib"\nfork = true\n' >"$WS/repos.toml"
rm "$WS/scripts/scripts/lib/repo-registry.py"
check "a missing registry reader keeps the gate on" is_not_fork "$WS/utils/forklib"

reuse_line=$(grep -n 'reuse lint' "$HOOK" | head -1 | cut -d: -f1)
guard=$(sed -n "$((reuse_line - 4)),${reuse_line}p" "$HOOK")
check "the pre-push REUSE gate asks repo-is-fork.sh first" grep -q 'repo-is-fork.sh' <<<"$guard"

echo "$PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
