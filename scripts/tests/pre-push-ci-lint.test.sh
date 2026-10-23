#!/usr/bin/env bash
# SPDX-FileCopyrightText: 2026 Mattia Egloff <mattia.egloff@pm.me>
# SPDX-License-Identifier: GPL-3.0-or-later

# Runs the pre-push CI lint (hooks/lib/ci-lint.sh) against real git repos
# with a stubbed `glab`, pinning how it wires its checks together
# (private#779): which changes it lints, when it trusts server lint, and
# what it says when the local parser is missing. The scripts it calls have
# their own unit tests; this guards the wiring between them.

set -uo pipefail

DIR="$(cd "$(dirname "$0")/../.." && pwd)"
LINT="$DIR/hooks/lib/ci-lint.sh"

pass=0
fail=0
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

# `glab` stub: logs its arguments, prints $GLAB_OUT, exits $GLAB_EXIT.
mkdir -p "$work/stub"
cat > "$work/stub/glab" <<'EOF'
#!/bin/sh
printf '%s\n' "$*" >> "$GLAB_LOG"
[ -n "${GLAB_OUT:-}" ] && printf '%s\n' "$GLAB_OUT"
exit "${GLAB_EXIT:-0}"
EOF
chmod +x "$work/stub/glab"

# The tools the lint runs, without python3 or uv.
mkdir -p "$work/noparser"
for tool in bash sh git grep sed awk tr dirname cat mktemp rm env head; do
    ln -s "$(command -v "$tool")" "$work/noparser/$tool"
done
ln -s "$work/stub/glab" "$work/noparser/glab"

# A repo whose origin/main has a tagged job in .gitlab-ci.yml and one in
# the local include ci/a.yml; prints its path.
make_repo() {
    # Six X's: BusyBox mktemp rejects fewer. An empty path would aim every
    # git command below at the current directory, so stop instead.
    repo=$(mktemp -d "$work/repo.XXXXXX") || true
    case "$repo" in
        "$work"/repo.*) [ -d "$repo" ] || exit 2 ;;
        *)
            echo "make_repo: mktemp failed, stopping before git runs in the wrong place" >&2
            exit 2
            ;;
    esac
    git -C "$repo" init -q
    git -C "$repo" config user.email test@example.invalid
    git -C "$repo" config user.name test
    mkdir -p "$repo/ci"
    printf 'a:\n  tags: [docker]\n  script: [echo ok]\n' > "$repo/ci/a.yml"
    printf 'include:\n  - local: ci/a.yml\ntop:\n  tags: [docker]\n  script: [echo ok]\n' \
        > "$repo/.gitlab-ci.yml"
    git -C "$repo" add -A
    git -C "$repo" commit -qm base
    git -C "$repo" update-ref refs/remotes/origin/main HEAD
}

commit_all() {
    git -C "$1" add -A
    git -C "$1" commit -qm "$2"
}

# run_lint <repo> [PATH]: sets $out, $rc and $glab_calls.
run_lint() {
    local path="${2:-$work/stub:$PATH}"
    : > "$work/glab.log"
    rc=0
    out=$(PATH="$path" GLAB_LOG="$work/glab.log" bash "$LINT" "$1" 2>&1) || rc=$?
    glab_calls=$(wc -l < "$work/glab.log" | tr -d ' ')
}

check() {
    local name="$1" ok="$2"
    if [ "$ok" = yes ]; then
        printf '  PASS %s\n' "$name"; pass=$((pass + 1))
    else
        printf '  FAIL %s — rc=%s glab_calls=%s\n%s\n' "$name" "$rc" "$glab_calls" "$out" >&2
        fail=$((fail + 1))
    fi
}

has() { printf '%s' "$out" | grep -qF -- "$1" && echo yes || echo no; }

# 1. A syntax error in the top file is blocked before server lint.
make_repo
printf 'broken:\n  tags: [docker]\n  cache:\n    fallback_keys: [x-${CI_DEFAULT_BRANCH}]\n  script: [echo ok]\n' \
    >> "$repo/.gitlab-ci.yml"
commit_all "$repo" "top-file error"
run_lint "$repo"
check "top-file YAML error → blocked" \
    "$([ "$rc" = 1 ] && [ "$(has 'flow sequence')" = yes ] && echo yes || echo no)"

# 2. An error only in an included file is blocked: it used to go unchecked.
make_repo
printf 'b:\n  tags: [docker]\n  script:\n    - test 1 = 1 || { echo "ERROR: x"; exit 1; }\n' \
    >> "$repo/ci/a.yml"
commit_all "$repo" "include error"
run_lint "$repo"
check "error only in an include → blocked" \
    "$([ "$rc" = 1 ] && [ "$(has 'is not a string')" = yes ] && echo yes || echo no)"

# 3. A harmless include edit passes, and server lint is not trusted with it.
make_repo
printf '# note\n' >> "$repo/ci/a.yml"
commit_all "$repo" "include comment"
run_lint "$repo"
check "harmless include edit → passes without server lint" \
    "$([ "$rc" = 0 ] && [ "$glab_calls" = 0 ] && [ "$(has 'server lint skipped')" = yes ] && echo yes || echo no)"

# 4. A top-file change with includes unchanged goes to server lint.
make_repo
printf '# note\n' >> "$repo/.gitlab-ci.yml"
commit_all "$repo" "top comment"
run_lint "$repo"
check "top-file change, includes on main → server lint runs" \
    "$([ "$rc" = 0 ] && [ "$glab_calls" = 1 ] && [ "$(has 'CI lint OK')" = yes ] && echo yes || echo no)"

# 5. A server lint verdict of invalid blocks the push.
GLAB_EXIT=1 GLAB_OUT="jobs:top config contains unknown keys: scirpt" run_lint "$repo"
check "server lint says invalid → blocked" \
    "$([ "$rc" = 1 ] && [ "$(has 'CI config is invalid')" = yes ] && echo yes || echo no)"

# 6. A branch that touches no CI file is not linted.
make_repo
printf 'x\n' > "$repo/README"
commit_all "$repo" "docs"
run_lint "$repo"
check "no CI change → nothing linted" \
    "$([ "$rc" = 0 ] && [ "$glab_calls" = 0 ] && [ "$(has 'Validating')" = no ] && echo yes || echo no)"

# 7. Main moving on is not this branch's change.
make_repo
git -C "$repo" switch -q -c topic
printf 'x\n' > "$repo/README"
commit_all "$repo" "docs"
git -C "$repo" switch -q -c main-ahead origin/main
printf '# main\n' >> "$repo/ci/a.yml"
commit_all "$repo" "main edits the include"
git -C "$repo" update-ref refs/remotes/origin/main HEAD
git -C "$repo" switch -q topic
run_lint "$repo"
check "main edited an include, branch did not → nothing linted" \
    "$([ "$rc" = 0 ] && [ "$(has 'Validating')" = no ] && echo yes || echo no)"

# 9. A job without runner tags in an include hangs like one in the top file.
make_repo
printf 'untagged:\n  script: [echo ok]\n' >> "$repo/ci/a.yml"
commit_all "$repo" "untagged job in include"
run_lint "$repo"
check "untagged job only in an include → blocked" \
    "$([ "$rc" = 1 ] && [ "$(has 'without runner tags')" = yes ] && [ "$(has 'untagged')" = yes ] && echo yes || echo no)"

# 8. A missing parser is named as such, not as a broken config.
make_repo
printf '# note\n' >> "$repo/.gitlab-ci.yml"
commit_all "$repo" "top comment"
run_lint "$repo" "$work/noparser"
check "no python3/PyYAML and no uv → blocked, naming the missing tool" \
    "$([ "$rc" = 1 ] && [ "$(has 'local parse unavailable')" = yes ] && [ "$(has 'does not parse')" = no ] && echo yes || echo no)"

printf '\n%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
