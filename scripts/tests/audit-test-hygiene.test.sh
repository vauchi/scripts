#!/usr/bin/env bash
# SPDX-FileCopyrightText: 2026 Mattia Egloff <mattia.egloff@pm.me>
#
# SPDX-License-Identifier: GPL-3.0-or-later
#
# Sentinel regression suite for audit-test-hygiene.sh — proves each
# counter rises on a real violation, the --check ratchet exits 1, and a
# count BELOW baseline still passes (ratchet-down). Non-tautological
# (CC-21). Builds throwaway core/vauchi-core/tests fixtures.

set -euo pipefail

set -u

SCRIPT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
SCRIPT="$SCRIPT_DIR/audit-test-hygiene.sh"

pass=0; fail=0
assert_eq() {
    name="$1"; want="$2"; got="$3"
    if [ "$want" = "$got" ]; then pass=$((pass+1)); printf '  PASS %s\n' "$name"
    else fail=$((fail+1)); printf '  FAIL %s\n    want: %s\n    got:  %s\n' "$name" "$want" "$got" >&2; fi
}

make_ws() { ws="$(mktemp -d)"; mkdir -p "$ws/core/vauchi-core/tests"; printf '%s' "$ws"; }
tdir() { printf '%s/core/vauchi-core/tests' "$1"; }
counter() { "$SCRIPT" "$1" 2>/dev/null | awk -v k="\"$2\":" '$1==k{gsub(/,/,"",$2);print $2;exit}'; }

ZERO_BASELINE="$(mktemp)"
cat > "$ZERO_BASELINE" <<'JSON'
{
  "schema_version": 1,
  "totals": {
    "test_sleeps":           0,
    "silent_skips":          0,
    "test_hygiene_total":    0
  }
}
JSON
check_rc() { "$SCRIPT" --check "$ZERO_BASELINE" "$1" >/dev/null 2>&1; printf '%s' "$?"; }

# ── 1. clean → all zero, --check passes ───────────────────────────────
ws=$(make_ws)
cat > "$(tdir "$ws")/clean.rs" <<'RS'
#[test] fn ok() { assert_eq!(2 + 2, 4); }
RS
assert_eq "clean: sleeps == 0" "0" "$(counter "$ws" test_sleeps)"
assert_eq "clean: skips == 0"  "0" "$(counter "$ws" silent_skips)"
assert_eq "clean: --check exits 0" "0" "$(check_rc "$ws")"
rm -rf "$ws"

# ── 2. thread::sleep in a test → counted, --check exits 1 ─────────────
ws=$(make_ws)
cat > "$(tdir "$ws")/sleepy.rs" <<'RS'
#[test] fn slow() { std::thread::sleep(std::time::Duration::from_millis(50)); }
RS
assert_eq "thread::sleep: test_sleeps == 1" "1" "$(counter "$ws" test_sleeps)"
assert_eq "thread::sleep: --check exits 1" "1" "$(check_rc "$ws")"
rm -rf "$ws"

# ── 3. tokio sleep also counted ───────────────────────────────────────
ws=$(make_ws)
cat > "$(tdir "$ws")/async_slow.rs" <<'RS'
async fn t() { tokio::time::sleep(d).await; }
RS
assert_eq "tokio sleep: test_sleeps == 1" "1" "$(counter "$ws" test_sleeps)"
rm -rf "$ws"

# ── 4. silent skip → counted, --check exits 1 ─────────────────────────
ws=$(make_ws)
cat > "$(tdir "$ws")/skip.rs" <<'RS'
#[test] fn maybe() {
    if missing() { eprintln!("SKIP: dependency absent"); return; }
    assert!(real());
}
RS
assert_eq "silent skip: silent_skips == 1" "1" "$(counter "$ws" silent_skips)"
assert_eq "silent skip: --check exits 1" "1" "$(check_rc "$ws")"
rm -rf "$ws"

# ── 5. comments not counted ───────────────────────────────────────────
ws=$(make_ws)
cat > "$(tdir "$ws")/comment.rs" <<'RS'
// uses std::thread::sleep historically; replaced with mock clock
// eprintln!("SKIP: old pattern")
#[test] fn clean() { assert!(true); }
RS
assert_eq "comment sleep: not counted" "0" "$(counter "$ws" test_sleeps)"
assert_eq "comment skip: not counted"  "0" "$(counter "$ws" silent_skips)"
rm -rf "$ws"

# ── 6. ratchet-down: a count BELOW baseline still passes ──────────────
ws=$(make_ws)
cat > "$(tdir "$ws")/one_sleep.rs" <<'RS'
#[test] fn slow() { std::thread::sleep(d); }
RS
BL="$(mktemp)"
cat > "$BL" <<'JSON'
{
  "schema_version": 1,
  "totals": {
    "test_sleeps":           3,
    "silent_skips":          0,
    "test_hygiene_total":    3
  }
}
JSON
"$SCRIPT" --check "$BL" "$ws" >/dev/null 2>&1
assert_eq "ratchet-down: 1 sleep under baseline 3 exits 0" "0" "$?"
rm -f "$BL"; rm -rf "$ws"

rm -f "$ZERO_BASELINE"
printf '\n%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
