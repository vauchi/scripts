#!/usr/bin/env bash
# SPDX-FileCopyrightText: 2026 Mattia Egloff <mattia.egloff@pm.me>
#
# SPDX-License-Identifier: GPL-3.0-or-later

# Sentinel for ci-templates/duplication.yml's before_script. The ratchet
# measures new clones against origin/$CI_DEFAULT_BRANCH, so the job must
# have git and must leave that ref behind. Its first run, core!2371
# (job 18123592780), died with "git: not found": node:22-alpine has no
# git (vauchi/private#1214).
#
# The before_script runs here as GitLab runs it, line by line under
# `sh -e`, with a PATH that has no git: a fake apk links the real one in
# when asked, a fake npm does nothing. The checkout is a shallow
# single-branch clone of a merge request branch, so a fetch that names
# only the branch updates FETCH_HEAD and never origin/main.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
TEMPLATE="$SCRIPT_DIR/../../ci-templates/duplication.yml"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

REAL_GIT="$(command -v git)"
REAL_SH="$(command -v sh)"
pass=0
fail=0

check() { # name, command...
    name="$1"; shift
    if "$@" >/dev/null 2>&1; then
        printf '  PASS %s\n' "$name"; pass=$((pass + 1))
    else
        printf '  FAIL %s\n' "$name" >&2; fail=$((fail + 1))
    fi
}

awk '
    /^  before_script:/ { on = 1; next }
    on && /^  [A-Za-z_]/ { exit }
    on && /^    - / { sub(/^    - /, ""); print }
' "$TEMPLATE" > "$WORK/before_script"
[ -s "$WORK/before_script" ] || { echo "FAIL: no before_script read from $TEMPLATE" >&2; exit 1; }

# An origin with main and an MR branch; the job's checkout of the branch.
git init -q -b main "$WORK/origin"
git -C "$WORK/origin" -c user.name=t -c user.email=t@t commit -q --allow-empty -m main
git -C "$WORK/origin" switch -q -c feature
git -C "$WORK/origin" -c user.name=t -c user.email=t@t commit -q --allow-empty -m feature
git clone -q --depth=1 --single-branch --branch feature "file://$WORK/origin" "$WORK/checkout"
main_sha="$(git -C "$WORK/origin" rev-parse main)"

mkdir "$WORK/bin"
printf '#!%s\nexit 0\n' "$REAL_SH" > "$WORK/bin/npm"
cat > "$WORK/bin/apk" <<EOF
#!$REAL_SH
for arg in "\$@"; do
    [ "\$arg" = git ] && /bin/ln -sf "$REAL_GIT" "$WORK/bin/git"
done
exit 0
EOF
chmod +x "$WORK/bin/npm" "$WORK/bin/apk"

run_before_script() {
    (
        cd "$WORK/checkout"
        export PATH="$WORK/bin" CI_DEFAULT_BRANCH=main JSCPD_VERSION=5.4.3
        while IFS= read -r line; do
            "$REAL_SH" -ec "$line" || exit 1
        done < "$WORK/before_script"
    )
}

check "before_script runs without git on the image" run_before_script
check "origin/main is the default branch's head" \
    test "$("$REAL_GIT" -C "$WORK/checkout" rev-parse --verify -q refs/remotes/origin/main 2>/dev/null)" = "$main_sha"

printf 'duplication-template: %d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
