#!/usr/bin/env bash
# SPDX-FileCopyrightText: 2026 Mattia Egloff <mattia.egloff@pm.me>
#
# SPDX-License-Identifier: GPL-3.0-or-later
#
# Sentinel suite for ci-templates/check-cla.sh — an MR author must be on
# the CLA signature list (docs/src/developers/cla-signatures.md), unless
# they are the maintainer or one of the group's access-token bots.

set -u

SCRIPT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
SCRIPT="$SCRIPT_DIR/../ci-templates/check-cla.sh"

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
has() { printf '%s' "$2" | grep -q -- "$1" && echo 1 || echo 0; }

LIST="$(mktemp)"
cat > "$LIST" <<'EOF'
# CLA Signatures

| Name | GitLab account | Date | CLA version |
|------|----------------|------|-------------|
| Ada Lovelace | @ada | 2026-10-25 | 1.1 |
| Grace Hopper | @GHopper | 2026-10-26 | 1.1 |
| Mallory Mention | @someone-else | 2026-10-26 | 1.1 |
EOF

run() { out="$(CLA_EXEMPT="${EXEMPT-megloff1}" "$SCRIPT" "$1" "$2" 2>&1)"; rc=$?; }

# ── a signer passes ───────────────────────────────────────────────────
run "$LIST" ada
assert_eq "signer: exit 0" "0" "$rc"

# ── accounts match case-insensitively, with or without the @ ─────────
run "$LIST" ghopper
assert_eq "case-insensitive: exit 0" "0" "$rc"
run "$LIST" @ada
assert_eq "leading @ on author: exit 0" "0" "$rc"

# ── an author who has not signed fails and is told how to sign ───────
run "$LIST" mallory
assert_eq "unsigned: exit 1" "1" "$rc"
assert_eq "unsigned: names the author" "1" "$(has '@mallory' "$out")"
assert_eq "unsigned: points to the CLA" "1" "$(has 'developers/cla.html' "$out")"

# ── only the account column counts, not a name containing the author ─
run "$LIST" mallory
assert_eq "name column ignored: exit 1" "1" "$rc"
run "$LIST" someone
assert_eq "account prefix is not a match: exit 1" "1" "$rc"

# ── the maintainer and the group's token bots are exempt ─────────────
run "$LIST" megloff1
assert_eq "maintainer: exit 0" "0" "$rc"
run "$LIST" group_122552022_bot_8430d9b80c28569925c8bfab4807c95f
assert_eq "group token bot: exit 0" "0" "$rc"
run "$LIST" project_77957857_bot_0123abcd
assert_eq "project token bot: exit 0" "0" "$rc"
run "$LIST" mallory_bot
assert_eq "bot-looking name is not exempt: exit 1" "1" "$rc"
EXEMPT="" run "$LIST" megloff1
assert_eq "empty exempt list exempts nobody: exit 1" "1" "$rc"

# ── a list with no signers yet still fails an outside author ─────────
EMPTY="$(mktemp)"
head -4 "$LIST" > "$EMPTY"
run "$EMPTY" ada
assert_eq "no signers: exit 1" "1" "$rc"
rm -f "$EMPTY"

# ── broken inputs fail loud (exit 2), never pass ─────────────────────
run /nonexistent/cla-signatures.md ada
assert_eq "missing list: exit 2" "2" "$rc"
NOTABLE="$(mktemp)"
printf '<html>Sign in</html>\n' > "$NOTABLE"
run "$NOTABLE" ada
assert_eq "file without the signature table: exit 2" "2" "$rc"
rm -f "$NOTABLE"
run "$LIST" ""
assert_eq "empty author: exit 2" "2" "$rc"

rm -f "$LIST"
printf '\ncheck-cla: %d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
