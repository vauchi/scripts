#!/usr/bin/env bash
# SPDX-FileCopyrightText: 2026 Mattia Egloff <mattia.egloff@pm.me>
#
# SPDX-License-Identifier: GPL-3.0-or-later
#
# Regression suite for hooks/lib/mr-report.sh.
#
# The bug this suite pins: glab 1.109 removed `--state`, the old inline
# block in hooks/pre-push discarded stderr, and so a hard CLI error read
# exactly like "no MRs found" — it announced "No open MR" for a branch
# with an open MR, and the merged-branch guard stopped firing entirely
# without a single visible symptom. Cases 5-6 are that failure.
#
# The opposite failure is just as reachable: `glab mr list` exits 0 and
# prints "No ... merge requests match your search" when empty, so an
# emptiness test of `-n "$output"` would make the guard block every push.
# Case 2 is that one.
#
# glab is stubbed via VAUCHI_GLAB_BIN — no network, no live GitLab.

set -u

SCRIPT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
REPORT="$SCRIPT_DIR/../hooks/lib/mr-report.sh"
WORK="/tmp/mr-report.test.$$"
mkdir -p "$WORK/bin" "$WORK/repo"
trap 'rm -rf "$WORK"' EXIT

pass=0
fail=0
assert_eq() {
    name="$1"; want="$2"; got="$3"
    if [ "$want" = "$got" ]; then
        printf '  PASS  %s\n' "$name"; pass=$((pass + 1))
    else
        printf '  FAIL  %s\n    want: %s\n    got:  %s\n' "$name" "$want" "$got"
        fail=$((fail + 1))
    fi
}
assert_contains() {
    name="$1"; needle="$2"; hay="$3"
    case "$hay" in
        *"$needle"*) printf '  PASS  %s\n' "$name"; pass=$((pass + 1)) ;;
        *) printf '  FAIL  %s\n    missing: %s\n    in: %s\n' "$name" "$needle" "$hay"
           fail=$((fail + 1)) ;;
    esac
}
assert_lacks() {
    name="$1"; needle="$2"; hay="$3"
    case "$hay" in
        *"$needle"*) printf '  FAIL  %s\n    unexpected: %s\n' "$name" "$needle"
                     fail=$((fail + 1)) ;;
        *) printf '  PASS  %s\n' "$name"; pass=$((pass + 1)) ;;
    esac
}

OPEN_ROW='!2216	vauchi/private!2216	feat: VGT09	(main) ← (feature/x)'
MERGED_ROW='!552	vauchi/vauchi!552	fix: layout gate	(main) ← (feature/x)'

# $1 = stdout for a plain (open) list, $2 = stdout for --merged, $3 = exit code
make_glab() {
    cat > "$WORK/bin/glab" <<EOF
#!/bin/bash
case "\$*" in
  *--merged*) cat <<'ROWS'
$2
ROWS
              ;;
  *api*)      echo '{"merged_at":"2000-01-01T00:00:00Z"}' ;;
  *)          cat <<'ROWS'
$1
ROWS
              ;;
esac
exit ${3:-0}
EOF
    chmod +x "$WORK/bin/glab"
}

run() {
    out=$(VAUCHI_GLAB_BIN="$WORK/bin/glab" bash "$REPORT" "$WORK/repo" "${1:-feature/x}" 2>&1)
    rc=$?
}

NO_OPEN='No open merge requests match your search in vauchi/private.'
NO_MERGED='No merged merge requests match your search in vauchi/private.'

# 1. An open MR is reported.
make_glab "$OPEN_ROW" "$NO_MERGED" 0
run
assert_eq "open MR: proceeds" 0 "$rc"
assert_contains "open MR: is listed" "!2216" "$out"

# 2. Empty results exit 0 and print a human message — they must NOT be
#    read as "a merged MR exists" just because glab printed prose.
make_glab "$NO_OPEN" "$NO_MERGED" 0
run
assert_eq "no MRs at all: proceeds" 0 "$rc"
assert_contains "no MRs at all: says so" "No open MR for branch feature/x" "$out"
assert_lacks "no MRs at all: does not claim a merged MR" "has a merged MR" "$out"

# 3. A merged MR with no open MR blocks the push.
make_glab "$NO_OPEN" "$MERGED_ROW" 0
run
assert_eq "merged branch: blocks" 1 "$rc"
assert_contains "merged branch: names the MR" "!552" "$out"

# 4. ... and the documented override releases it.
out=$(VAUCHI_GLAB_BIN="$WORK/bin/glab" ALLOW_MERGED_BRANCH=1 \
    bash "$REPORT" "$WORK/repo" feature/x 2>&1); rc=$?
assert_eq "merged branch: override proceeds" 0 "$rc"

# 5-6. A FAILING query (the glab 1.109 flag removal) must never be
#      reported as an absence, and must never block.
make_glab 'ERROR: Unknown flag: --state.' 'ERROR: Unknown flag: --state.' 1
run
assert_eq "glab error: proceeds" 0 "$rc"
assert_contains "glab error: is surfaced" "failed" "$out"
assert_lacks "glab error: not reported as no-MR" "No open MR for branch" "$out"

# 7. main is never reported on.
make_glab "$OPEN_ROW" "$NO_MERGED" 0
run main
assert_eq "main: silent" 0 "$rc"
assert_eq "main: no output" "" "$out"

# 8. A missing glab degrades to silence, not to a block.
out=$(VAUCHI_GLAB_BIN="$WORK/bin/absent-glab" bash "$REPORT" "$WORK/repo" feature/x 2>&1)
rc=$?
assert_eq "no glab installed: proceeds" 0 "$rc"

printf '\nmr-report: %d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
