#!/usr/bin/env bash
# SPDX-FileCopyrightText: 2026 Mattia Egloff <mattia.egloff@pm.me>
#
# SPDX-License-Identifier: GPL-3.0-or-later
#
# Sentinel suite for scripts/hooks/commit-msg — VGT15: a commit that stages
# public text (docs, spec, website copy, blog, feature files, READMEs) says
# what shipped work it describes, with a `Shipped-in:` trailer.
# Rule page: _private/docs/lint-errors/vgt15-shipped-in-trailer.md
set -u

HOOKS_DIR="$(cd "$(dirname "$0")/../../hooks" && pwd)"
HOOK="$HOOKS_DIR/commit-msg"
pass=0
fail=0

assert_eq() {
    name="$1"; want="$2"; got="$3"
    if [ "$want" = "$got" ]; then
        pass=$((pass + 1)); printf '  PASS %s\n' "$name"
    else
        fail=$((fail + 1))
        printf '  FAIL %s\n    want: %s\n    got:  %s\n' "$name" "$want" "$got" >&2
    fi
}

run_case() { # $1=repo name  $2=message  $3..=paths to stage → sets rc, out
    name="$1"; msg="$2"; shift 2
    parent="$(mktemp -d)"
    repo="$parent/$name"
    mkdir -p "$repo"
    git -C "$repo" init -q
    git -C "$repo" config user.email t@example.com
    git -C "$repo" config user.name t
    git -C "$repo" commit -q --allow-empty -m "chore: root"
    for p in "$@"; do
        mkdir -p "$repo/$(dirname "$p")"
        printf 'x\n' > "$repo/$p"
        git -C "$repo" add "$p"
    done
    printf '%s\n' "$msg" > "$repo/.msg"
    out="$(cd "$repo" && "$HOOK" .msg 2>&1)"; rc=$?
    rm -rf "$parent"
}

has() { printf '%s' "$out" | grep -qE "$1" && echo 1 || echo 0; }

# ── public text without the trailer → rejected, with the fix and the page ─
run_case docs 'docs: the exchange page explains Link mode' src/users/features/contact-exchange.md
assert_eq "docs page without Shipped-in: exit 1" "1" "$rc"
assert_eq "docs page without Shipped-in: VGT15 in message" "1" "$(has 'VGT15:')"
assert_eq "docs page without Shipped-in: names the fix" "1" "$(has 'VGT15: .+ — fix: .+')"
assert_eq "docs page without Shipped-in: cites the page" "1" "$(has 'lint-errors/vgt15-shipped-in-trailer.md')"

# ── every commit type is covered, not only feat/fix/docs ─────────────────
run_case spec 'tidy: reflow the relay chapter' src/protocols/relay.md
assert_eq "tidy on a spec page without Shipped-in: exit 1" "1" "$rc"
run_case features 'chore: retag a scenario' sealed_mailbox.feature
assert_eq "chore on a feature file without Shipped-in: exit 1" "1" "$rc"
run_case website 'refactor: split the landing copy' i18n/en.json
assert_eq "refactor on website copy without Shipped-in: exit 1" "1" "$rc"
# Blog posts are dated opinion the owner reviews in the CMS MR, not product
# documentation (owner, 2026-11-12, vauchi/private#1237).
run_case website 'docs: a new post' blog/content/a-post.md
assert_eq "blog post without Shipped-in: exit 0" "0" "$rc"
run_case relay 'docs: describe the purge route' README.md
assert_eq "a repo README without Shipped-in: exit 1" "1" "$rc"
run_case core 'docs: the crate README' vauchi-core/README.md
assert_eq "a nested README without Shipped-in: exit 1" "1" "$rc"

# ── each accepted value ───────────────────────────────────────────────
for value in 'core!2329' 'relay@0f5cffb' 'roadmap' 'limit' 'correction core@5ff8f8dad' \
             'n/a — typo' 'n/a — link' 'n/a — formatting' 'n/a — translation'; do
    run_case docs "docs: a page

Shipped-in: $value" src/index.md
    assert_eq "Shipped-in: $value: exit 0" "0" "$rc"
done

# ── several trailers for a mixed commit ───────────────────────────────
run_case docs 'docs: two pages

Shipped-in: core!2329
Shipped-in: limit' src/a.md src/b.md
assert_eq "two Shipped-in trailers: exit 0" "0" "$rc"

# ── escape hatches the grilling named → rejected ──────────────────────
for value in 'n/a — clarification' 'n/a' 'correction' 'yes' 'core' '!2329' 'core@xyz' ''; do
    run_case docs "docs: a page

Shipped-in: $value" src/index.md
    assert_eq "Shipped-in: '$value': exit 1" "1" "$rc"
done
run_case docs 'docs: a page

Shipped-in: limit
Shipped-in: n/a — because' src/index.md
assert_eq "one bad trailer among good ones: exit 1" "1" "$rc"

# ── outside public text, or wip, or the private repo → not asked ───────
run_case docs 'chore: bump mdbook' book.toml .gitlab-ci.yml
assert_eq "docs repo, no page staged: exit 0" "0" "$rc"
run_case core 'feat: a step with no public text' vauchi-core/src/lib.rs
assert_eq "code only: exit 0" "0" "$rc"
run_case docs 'wip: half a page' src/index.md
assert_eq "wip: on a page: exit 0" "0" "$rc"
run_case _private 'docs: a design' docs/designs/x.md README.md
assert_eq "_private: exit 0" "0" "$rc"
run_case docs 'docs: a theme file' src/theme/custom.css
assert_eq "docs non-markdown asset: exit 0" "0" "$rc"

printf '\n%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
