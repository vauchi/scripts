#!/usr/bin/env bash
# SPDX-FileCopyrightText: 2026 Mattia Egloff <mattia.egloff@pm.me>
#
# SPDX-License-Identifier: GPL-3.0-or-later
#
# check-shipped-in.sh --range: the CI re-check of VGT15 over an MR's
# commits. It catches what the local hook cannot (--no-verify, web edits)
# and resolves every citation: an MR must be merged, a sha on main.
# The GitLab API is stubbed through SHIPPED_IN_API.
set -u

SCRIPT="$(cd "$(dirname "$0")/.." && pwd)/check-shipped-in.sh"
pass=0
fail=0
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

assert_eq() {
    name="$1"; want="$2"; got="$3"
    if [ "$want" = "$got" ]; then
        pass=$((pass + 1)); printf '  PASS %s\n' "$name"
    else
        fail=$((fail + 1))
        printf '  FAIL %s\n    want: %s\n    got:  %s\n' "$name" "$want" "$got" >&2
    fi
}

# Stub: core!2329 merged, core!9 open, relay@0f5cffb on main, relay@1111111
# only on a branch; the path "down" fails like an outage.
cat > "$work/api" <<'EOF'
#!/usr/bin/env bash
case "$1" in
    *core/merge_requests/2329) echo '{"state": "merged"}' ;;
    *core/merge_requests/9) echo '{"state": "opened"}' ;;
    *relay/repository/commits/0f5cffb/refs*) echo '[{"type": "branch", "name": "main"}]' ;;
    *relay/repository/commits/1111111/refs*) echo '[{"type": "branch", "name": "issue/1"}]' ;;
    *down*) exit 1 ;;
    *) echo '{}' ;;
esac
EOF
chmod +x "$work/api"
export SHIPPED_IN_API="$work/api"

new_repo() { # $1=name → repo path with a root commit, prints path
    r="$work/$1-$RANDOM"
    mkdir -p "$r"
    git -C "$r" init -q
    git -C "$r" config user.email t@example.com
    git -C "$r" config user.name t
    git -C "$r" commit -q --allow-empty -m "chore: root"
    printf '%s' "$r"
}

commit_file() { # $1=repo $2=path $3=message
    mkdir -p "$1/$(dirname "$2")"
    printf '%s\n' "$RANDOM" >> "$1/$2"
    git -C "$1" add "$2"
    git -C "$1" commit -q --no-verify -m "$3"
}

run_range() { # $1=repo $2=repo-name → rc, out
    base=$(git -C "$1" rev-list --max-parents=0 HEAD)
    out="$(cd "$1" && "$SCRIPT" --range "$base" HEAD "$2" 2>&1)"; rc=$?
}

r=$(new_repo docs)
commit_file "$r" src/index.md 'docs: a page

Shipped-in: core!2329'
run_range "$r" docs
assert_eq "cited MR merged: exit 0" "0" "$rc"

r=$(new_repo docs)
commit_file "$r" src/index.md 'docs: a page

Shipped-in: core!9'
run_range "$r" docs
assert_eq "cited MR still open: exit 1" "1" "$rc"
assert_eq "cited MR still open: says so" "1" "$(printf '%s' "$out" | grep -c 'not merged or not on main')"

r=$(new_repo docs)
commit_file "$r" src/index.md 'docs: a page

Shipped-in: relay@0f5cffb'
run_range "$r" docs
assert_eq "cited sha on main: exit 0" "0" "$rc"

r=$(new_repo docs)
commit_file "$r" src/index.md 'docs: a page

Shipped-in: correction relay@1111111'
run_range "$r" docs
assert_eq "correction citing a sha only on a branch: exit 1" "1" "$rc"

r=$(new_repo docs)
commit_file "$r" src/index.md 'docs: a page, committed with --no-verify'
run_range "$r" docs
assert_eq "no trailer, hook bypassed: exit 1" "1" "$rc"

r=$(new_repo docs)
commit_file "$r" src/index.md 'docs: a page

Shipped-in: down!1'
run_range "$r" docs
assert_eq "API unreachable: exit 2, not a pass" "2" "$rc"

r=$(new_repo docs)
commit_file "$r" src/index.md 'docs: a page

Shipped-in: private!4068'
run_range "$r" docs
assert_eq "a private reference is checked for form only: exit 0" "0" "$rc"

r=$(new_repo docs)
commit_file "$r" src/index.md 'docs: a page

Shipped-in: limit'
commit_file "$r" src/other.md 'docs: another page'
run_range "$r" docs
assert_eq "one bad commit among good ones fails the range: exit 1" "1" "$rc"

r=$(new_repo docs)
commit_file "$r" book.toml 'chore: bump mdbook'
commit_file "$r" src/index.md 'wip: half a page'
run_range "$r" docs
assert_eq "no public text, and wip: exit 0" "0" "$rc"

r=$(new_repo _private)
commit_file "$r" README.md 'docs: private notes'
run_range "$r" _private
assert_eq "_private: exit 0" "0" "$rc"

out="$("$SCRIPT" --range 2>&1)"; rc=$?
assert_eq "missing arguments: exit 2" "2" "$rc"

printf '\n%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
