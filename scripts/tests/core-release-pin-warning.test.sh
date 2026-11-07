#!/bin/sh
# SPDX-FileCopyrightText: 2026 Mattia Egloff <mattia.egloff@pm.me>
# SPDX-License-Identifier: GPL-3.0-or-later

set -eu
repo_root=$(CDPATH='' cd "$(dirname "$0")/../.." && pwd)
helper="$repo_root/hooks/lib/core-release-pin-warning.sh"
fixture=$(mktemp -d)
trap 'rm -rf "$fixture"' EXIT

write_pin() {
    cat > "$fixture/Cargo.toml" <<EOF
[dependencies]
vauchi-core = { git = "https://gitlab.com/vauchi/core.git", tag = "$1", version = "=0.100.2" }
EOF
    cat > "$fixture/Cargo.lock" <<EOF
version = 4
[[package]]
name = "vauchi-core"
version = "0.100.2"
source = "git+https://gitlab.com/vauchi/core.git?tag=$1#aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
EOF
}

write_pin v0.100.2
output=$(sh "$helper" "$fixture")
[ -z "$output" ] || { echo "FAIL: stable pin warned"; exit 1; }

write_pin v0.100.2-dev.6
output=$(sh "$helper" "$fixture")
case "$output" in
    *WARNING:*"not a stable Core release"*) ;;
    *) echo "FAIL: development push did not warn"; exit 1 ;;
esac

printf '[dependencies]\nserde = "1"\n' > "$fixture/Cargo.toml"
output=$(sh "$helper" "$fixture")
[ -z "$output" ] || { echo "FAIL: unrelated manifest warned"; exit 1; }

python3 - "$repo_root/hooks/pre-push" <<'PY'
import pathlib
import sys
hook = pathlib.Path(sys.argv[1]).read_text()
assert 'sh "$HOOK_DIR/lib/core-release-pin-warning.sh" "$REPO_ROOT"' in hook
PY
echo "core-release-pin-warning.test: PASS"
