#!/bin/bash
# SPDX-FileCopyrightText: 2026 Mattia Egloff <mattia.egloff@pm.me>
#
# SPDX-License-Identifier: GPL-3.0-or-later
#
# for_each_repo drives just git status, fetch and sync. The tools and
# forks cloned under utils/ (vauchi/utils, private#1034) are repositories
# too: a loop over the top level alone dropped them, so their unpushed
# work went unseen. Pin: top-level clones and utils/ clones are visited,
# directories without .git are not.
set -euo pipefail
here="$(cd "$(dirname "$0")/.." && pwd)"
ws="$(mktemp -d)"
trap 'rm -rf "$ws"' EXIT
mkdir -p "$ws/core/.git" "$ws/utils/tool/.git" "$ws/utils/notarepo" "$ws/plain"
visited="$(
    cd "$ws"
    # shellcheck source=../for-each-repo.sh
    source "$here/for-each-repo.sh"
    collect() { echo "$1=$2"; }
    for_each_repo --no-root collect
)"
expected="core=core
utils/tool=utils/tool"
if [[ "$visited" != "$expected" ]]; then
    echo "FAIL: for_each_repo visited:"
    printf '%s\n' "$visited"
    exit 1
fi
echo "PASS: for_each_repo visits top-level and utils/ clones only"
