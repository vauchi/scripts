#!/usr/bin/env bash
# SPDX-FileCopyrightText: 2026 Mattia Egloff <mattia.egloff@pm.me>
# SPDX-License-Identifier: GPL-3.0-or-later

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")/../.." && pwd)"
INSTALLER="$SCRIPT_DIR/install-hooks.sh"
WORK="$(mktemp -d)"
WORK="$(cd "$WORK" && pwd -P)"
trap 'rm -rf "$WORK"' EXIT

pass=0
fail=0

assert_eq() {
    name="$1"
    expected="$2"
    actual="$3"
    if [[ "$expected" == "$actual" ]]; then
        pass=$((pass + 1))
        printf '  PASS %s\n' "$name"
    else
        fail=$((fail + 1))
        printf '  FAIL %s\n    expected: %s\n    actual:   %s\n' \
            "$name" "$expected" "$actual" >&2
    fi
}

workspace="$WORK/workspace"
canonical_scripts="$workspace/scripts"
scripts_worktree="$workspace/.worktrees/installer/scripts"
canonical_hooks="$canonical_scripts/hooks"
disposable_hooks="$scripts_worktree/hooks"

mkdir -p "$canonical_scripts/hooks" "$workspace/core" "$workspace/utils/fork"
cp "$INSTALLER" "$canonical_scripts/install-hooks.sh"
printf '#!/usr/bin/env bash\nexit 0\n' > "$canonical_hooks/pre-push"

git -C "$canonical_scripts" init -q
git -C "$canonical_scripts" config user.email test@example.com
git -C "$canonical_scripts" config user.name tester
git -C "$canonical_scripts" add install-hooks.sh hooks/pre-push
git -C "$canonical_scripts" commit -qm fixture
mkdir -p "$(dirname "$scripts_worktree")"
git -C "$canonical_scripts" worktree add -q -b installer "$scripts_worktree"

git -C "$workspace/core" init -q
# Tools and forks are cloned under utils/ (private#1034).
git -C "$workspace/utils/fork" init -q
git -C "$canonical_scripts" config core.hooksPath "$disposable_hooks"
git -C "$workspace/core" config core.hooksPath "$disposable_hooks"

bash "$scripts_worktree/install-hooks.sh" >/dev/null

assert_eq "worktree invocation heals sibling repository hooks" \
    "$canonical_hooks" \
    "$(git -C "$workspace/core" config --local --get core.hooksPath)"
assert_eq "worktree invocation heals shared scripts hooks" \
    "$canonical_hooks" \
    "$(git -C "$canonical_scripts" config --local --get core.hooksPath)"

assert_eq "a clone under utils/ gets the shared hooks" \
    "$canonical_hooks" \
    "$(git -C "$workspace/utils/fork" config --local --get core.hooksPath || true)"

printf '\ninstall-hooks.test: %d passed, %d failed\n' "$pass" "$fail"
[[ "$fail" -eq 0 ]]
