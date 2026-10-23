#!/usr/bin/env bash
# SPDX-FileCopyrightText: 2026 Mattia Egloff <mattia.egloff@pm.me>
# SPDX-License-Identifier: GPL-3.0-or-later

set -euo pipefail
checker=$(cd "$(dirname "$0")/.." && pwd)/check-new-test-annotations.sh
scratch=$(mktemp -d)
trap 'rm -rf "$scratch"' EXIT
git init -q "$scratch/repo"
cd "$scratch/repo"
git config user.name Fixture
git config user.email fixture@example.invalid
git config diff.renames copy
mkdir src
cat > src/old.rs <<'RS'
#[test]
fn moved_contract() {
    let value = 42;
    assert_eq!(value, 42);
}
RS
git add src/old.rs
git commit -qm 'fixture: original test'
base=$(git rev-parse HEAD)
cp src/old.rs src/new.rs
printf 'pub use crate::new::*;\n' > src/old.rs
git add src
git commit -qm 'fixture: relocate test and retain alias'
if bash "$checker" "$base" > "$scratch/red.log" 2>&1; then
    echo 'FAIL: copy detection hid an unannotated relocated test' >&2
    exit 1
fi
grep -q '1 new test(s) missing annotations' "$scratch/red.log"
{
    printf '// @internal — fixture contract\n'
    cat src/new.rs
} > "$scratch/annotated.rs"
cp "$scratch/annotated.rs" src/new.rs
git add src/new.rs
git commit -qm 'fixture: annotate relocated test'
bash "$checker" "$base" > "$scratch/green.log"
grep -q 'All 1 new test(s) have annotations' "$scratch/green.log"
echo 'PASS: relocated tests are checked independently of Git copy detection'
