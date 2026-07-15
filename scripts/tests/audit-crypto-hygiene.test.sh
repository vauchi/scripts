#!/usr/bin/env bash
# SPDX-FileCopyrightText: 2026 Mattia Egloff <mattia.egloff@pm.me>
#
# SPDX-License-Identifier: GPL-3.0-or-later
#
# Sentinel regression suite for audit-crypto-hygiene.sh — proves each
# counter rises on a real violation and the --check ratchet exits 1
# (non-tautological per CC-21). Builds throwaway core/vauchi-core/src
# fixtures; no dependency on the live tree.

set -euo pipefail

set -u

SCRIPT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
SCRIPT="$SCRIPT_DIR/audit-crypto-hygiene.sh"

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

make_ws() { ws="$(mktemp -d)"; mkdir -p "$ws/core/vauchi-core/src"; printf '%s' "$ws"; }
src() { printf '%s/core/vauchi-core/src' "$1"; }
counter() {
    "$SCRIPT" "$1" 2>/dev/null \
        | awk -v k="\"$2\":" '$1==k { gsub(/,/,"",$2); print $2; exit }'
}

ZERO_BASELINE="$(mktemp)"
cat > "$ZERO_BASELINE" <<'JSON'
{ "schema_version": 2, "totals": {
  "hkdf_empty_info": 0, "hkdf_dup_info": 0, "hkdf_raw_bypass": 0,
  "hkdf_unparsed_calls": 0, "argon2_const_salt": 0,
  "trust_level_setters": 0, "crypto_hygiene_total": 0 } }
JSON
check_rc() { "$SCRIPT" --check "$ZERO_BASELINE" "$1" >/dev/null 2>&1; printf '%s' "$?"; }

# ── 1. clean → all zero, --check passes ───────────────────────────────
ws=$(make_ws)
cat > "$(src "$ws")/clean.rs" <<'RS'
fn f() { let _k = HKDF::derive_key(None, &ikm, b"vauchi-clean-unique-v1"); }
RS
assert_eq "clean: empty == 0" "0" "$(counter "$ws" hkdf_empty_info)"
assert_eq "clean: dup == 0"   "0" "$(counter "$ws" hkdf_dup_info)"
assert_eq "clean: --check exits 0" "0" "$(check_rc "$ws")"
rm -rf "$ws"

# ── 2. empty info → exits 1 ───────────────────────────────────────────
ws=$(make_ws)
cat > "$(src "$ws")/empty.rs" <<'RS'
fn f() { let _k = HKDF::derive_key(None, &ikm, b""); }
RS
assert_eq "empty-info: empty == 1" "1" "$(counter "$ws" hkdf_empty_info)"
assert_eq "empty-info: --check exits 1" "1" "$(check_rc "$ws")"
rm -rf "$ws"

# ── 3. literal collision (two purposes, same string) → dup ────────────
ws=$(make_ws)
cat > "$(src "$ws")/purpose_a.rs" <<'RS'
fn a() { let _k = HKDF::derive_key(None, &ka, b"vauchi-collide-v9"); }
RS
cat > "$(src "$ws")/purpose_b.rs" <<'RS'
fn b() { let _k = HKDF::derive_key(None, &kb, b"vauchi-collide-v9"); }
RS
assert_eq "collision: dup == 1" "1" "$(counter "$ws" hkdf_dup_info)"
assert_eq "collision: --check exits 1" "1" "$(check_rc "$ws")"

# ── 4. allow-list value:COUNT — exact count permitted → dup 0 ─────────
allow="$(mktemp)"; printf 'vauchi-collide-v9:2\n' > "$allow"
got=$(CRYPTO_HYGIENE_ALLOWLIST="$allow" counter "$ws" hkdf_dup_info)
assert_eq "allow-list exact count: dup == 0" "0" "$got"

# ── 4b. a NEW (3rd) use of the allow-listed string EXCEEDS count → dup ─
cat > "$(src "$ws")/purpose_c.rs" <<'RS'
fn c() { let _k = HKDF::derive_key(None, &kc, b"vauchi-collide-v9"); }
RS
got=$(CRYPTO_HYGIENE_ALLOWLIST="$allow" counter "$ws" hkdf_dup_info)
assert_eq "allow-list reuse-for-new-purpose: dup == 1 (count exceeded)" "1" "$got"
rm -f "$allow"; rm -rf "$ws"

# ── 5. cross-form: const value == inline literal (same file) → dup ────
ws=$(make_ws)
cat > "$(src "$ws")/crossform.rs" <<'RS'
const DUP_INFO: &[u8] = b"vauchi-xform-v1";
fn a() { let _k = HKDF::derive_key(None, &ka, DUP_INFO); }
fn b() { let _k = HKDF::derive_key(None, &kb, b"vauchi-xform-v1"); }
RS
assert_eq "cross-form const==literal: dup == 1" "1" "$(counter "$ws" hkdf_dup_info)"
rm -rf "$ws"

# ── 6. module-scoped same-named consts, distinct values → no collision ─
ws=$(make_ws)
cat > "$(src "$ws")/mod_a.rs" <<'RS'
const HKDF_INFO: &[u8] = b"vauchi-aaa-v1";
fn a() { let _k = HKDF::expand(&prk, HKDF_INFO, 32); }
RS
cat > "$(src "$ws")/mod_b.rs" <<'RS'
const HKDF_INFO: &[u8] = b"vauchi-bbb-v1";
fn b() { let _k = HKDF::expand(&prk, HKDF_INFO, 32); }
RS
assert_eq "module-scoped consts: dup == 0" "0" "$(counter "$ws" hkdf_dup_info)"
rm -rf "$ws"

# ── 7. raw Hkdf::< OUTSIDE the wrapper file → bypass counted, exits 1 ──
ws=$(make_ws)
cat > "$(src "$ws")/sneaky.rs" <<'RS'
use hkdf::Hkdf;
fn s() { let hk = Hkdf::<Sha256>::new(salt, ikm); hk.expand(info, &mut o); }
RS
got=$(counter "$ws" hkdf_raw_bypass)
assert_eq "raw bypass outside kdf.rs: counted (>=1)" "1" "$([ "$got" -ge 1 ] && echo 1 || echo 0)"
assert_eq "raw bypass: --check exits 1" "1" "$(check_rc "$ws")"
rm -rf "$ws"

# ── 8. raw Hkdf::< INSIDE kdf.rs (the wrapper) → NOT counted ──────────
ws=$(make_ws)
cat > "$(src "$ws")/kdf.rs" <<'RS'
use hkdf::Hkdf;
pub struct HKDF;
impl HKDF { fn x() { let hk = Hkdf::<Sha256>::new(salt, ikm); } }
RS
assert_eq "raw in kdf.rs (wrapper): bypass == 0" "0" "$(counter "$ws" hkdf_raw_bypass)"
rm -rf "$ws"

# ── 9. multi-line derive call → unparsed tripwire, exits 1 ────────────
ws=$(make_ws)
cat > "$(src "$ws")/multiline.rs" <<'RS'
fn m() {
    let _k = HKDF::derive_key(
        None, &ikm, b"vauchi-wrapped-v1");
}
RS
assert_eq "multi-line call: unparsed == 1" "1" "$(counter "$ws" hkdf_unparsed_calls)"
assert_eq "multi-line call: --check exits 1" "1" "$(check_rc "$ws")"
rm -rf "$ws"

# ── 10. Argon2 with a literal (constant) salt → counted, exits 1 ─────
ws=$(make_ws)
cat > "$(src "$ws")/argon.rs" <<'RS'
fn a() { let _k = derive_key_argon2id(password, b"hardcoded-salt"); }
RS
assert_eq "argon2 const salt: counted == 1" "1" "$(counter "$ws" argon2_const_salt)"
assert_eq "argon2 const salt: --check exits 1" "1" "$(check_rc "$ws")"
rm -rf "$ws"

# ── 11. trust setter → counted, exits 1 ───────────────────────────────
ws=$(make_ws)
cat > "$(src "$ws")/trust_bad.rs" <<'RS'
impl Contact { pub fn set_trust_level(&mut self, l: TrustLevel) { self.trust_level = l; } }
RS
got=$(counter "$ws" trust_level_setters)
assert_eq "trust setter: counted (>=1)" "1" "$([ "$got" -ge 1 ] && echo 1 || echo 0)"
assert_eq "trust setter: --check exits 1" "1" "$(check_rc "$ws")"
rm -rf "$ws"

# ── 12. set_trust_metrics + getter → NOT counted; wire field NOT counted ─
ws=$(make_ws)
cat > "$(src "$ws")/trust_ok.rs" <<'RS'
pub struct SyncDelta { pub trust_level: String }
impl Contact {
    pub fn set_trust_metrics(&mut self, m: Option<TrustMetrics>) { self.metrics = m; }
    pub fn trust_level(&self) -> TrustLevel { TrustLevel::Standard }
}
RS
assert_eq "metrics+getter+wire-field: setters == 0" "0" "$(counter "$ws" trust_level_setters)"
rm -rf "$ws"

# ── 13. comment-only derive line not counted ─────────────────────────
ws=$(make_ws)
cat > "$(src "$ws")/comment.rs" <<'RS'
// example: HKDF::derive_key(None, &ikm, b"")
fn f() {}
RS
assert_eq "comment: empty == 0" "0" "$(counter "$ws" hkdf_empty_info)"
rm -rf "$ws"

rm -f "$ZERO_BASELINE"
printf '\n%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
