#!/usr/bin/env bash
# SPDX-FileCopyrightText: 2026 Mattia Egloff <mattia.egloff@pm.me>
#
# SPDX-License-Identifier: GPL-3.0-or-later

# audit-crypto-hygiene.sh — Mechanical ratchet for the grep-tractable
# subset of the honor-system crypto rules in adr-constraints.md §Crypto.
#
# IMPORTANT — what this does NOT do: it is a TEXT regression ratchet, not
# semantic analysis. A green run means "these patterns did not regress",
# never "the crypto is correct". It does not execute crypto, verify IKM /
# salt / output length / algorithm choice, or check zeroization. Real
# correctness lives in KATs / property tests (CC-04) / the never-mock
# crypto suite / audit. This is a cheap tripwire layer.
#
# Mirrors the pure-functional-core seal (audit-mobile-surface.sh
# --check-core-purity): a portable source audit, baselined at 0, wired
# hard into gate-push.sh (core) and a lint:crypto-hygiene CI job.
#
# Plan: _private/docs/planning/todo/2026-06-05-crypto-hygiene-ratchet-plan.md
#
# Counters (all baseline 0 — invariants that must hold, not debt):
#
#   hkdf_empty_info     — a HKDF::derive_key/expand call whose `info`
#                         (domain-separation) arg is the empty byte string
#                         b"". ADR-007: every derivation path has a UNIQUE,
#                         non-empty info string.
#   hkdf_dup_info       — a resolved `info` value used at MORE sites than
#                         the allow-list permits. Two DIFFERENT derivation
#                         purposes sharing a string breaks domain
#                         separation. The allow-list is value:COUNT — a
#                         shared string is pinned to its exact known site
#                         count, so a NEW use of an allow-listed string
#                         (reuse for a new purpose) still trips the gate.
#   hkdf_raw_bypass     — raw `Hkdf::<…>` / `hkdf::Hkdf` usage OUTSIDE the
#                         wrapper file (crypto/kdf.rs). The empty/dup checks
#                         only see callers of the `HKDF::` wrapper; this
#                         forces all HKDF through that seam so nothing
#                         derives keys invisibly. (Closes the wrapper-
#                         coupling blind spot.)
#   hkdf_unparsed_calls — a HKDF::derive_key/expand call the single-line
#                         extractor could not parse (args wrapped onto a
#                         later line). Baseline 0 turns the v1 single-line
#                         limitation from a silent false-negative into a
#                         visible tripwire: keep derive calls single-line.
#   argon2_const_salt   — an Argon2 derivation (derive_key_argon2id /
#                         hash_password_into) called with a literal b"…"
#                         salt. Salts must be per-derivation random, never
#                         a hardcoded constant.
#   trust_level_setters — a `fn set_trust_level` or assignment to a stored
#                         `.trust_level` field. ADR-034: trust level is a
#                         pure deterministic derivation, never settable.
#                         `set_trust_metrics` (derivation INPUTS) is fine.
#                         LIMIT: name/pattern-coupled — a differently-named
#                         setter (`force_verified`) is not caught. The real
#                         guarantee is structural (trust is a computed
#                         getter with no stored contact field); this is a
#                         backstop. Wire/sync `trust_level` fields (e.g.
#                         sync/delta.rs) are struct-init, not `.x =`
#                         assignment, so are correctly NOT flagged.
#
# Usage:
#   audit-crypto-hygiene.sh [workspace_root]
#       Emit the JSON snapshot on stdout. Exit 0 (the JSON is the result);
#       exit 2 only on internal error (bad workspace root).
#   audit-crypto-hygiene.sh --check <baseline.json> [workspace_root]
#       Ratchet mode. Exit 1 if ANY count EXCEEDS its baseline value.
#
# Scope: core/vauchi-core/src only. Default workspace_root: two levels up
# from this script so the CI symlink layout (WS/core -> project) resolves
# identically to the seal job.
#
# Portability: POSIX shell + BSD/GNU/BusyBox utilities only. No grep -P,
# no bash arrays, no GNU --include/--exclude, no awk gensub, no mapfile.
# Verified under alpine:3.21 BusyBox awk/grep/sed (2026-06-05).

set -euo pipefail

# ── arg parsing ───────────────────────────────────────────────────────
CHECK_MODE=0
BASELINE_FILE=""
if [ "${1:-}" = "--check" ]; then
    CHECK_MODE=1
    BASELINE_FILE="${2:-}"
    if [ -z "$BASELINE_FILE" ]; then
        printf 'audit-crypto-hygiene: --check requires a baseline file\n' >&2
        exit 2
    fi
    if [ ! -f "$BASELINE_FILE" ]; then
        printf 'audit-crypto-hygiene: baseline %s not found\n' "$BASELINE_FILE" >&2
        exit 2
    fi
    shift 2
fi

# ── locate workspace root + inputs ────────────────────────────────────
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
DEFAULT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
WORKSPACE_ROOT="${1:-$DEFAULT_ROOT}"

if [ ! -d "$WORKSPACE_ROOT" ]; then
    printf 'audit-crypto-hygiene: workspace_root %s is not a directory\n' \
        "$WORKSPACE_ROOT" >&2
    exit 2
fi
WORKSPACE_ROOT="$(cd "$WORKSPACE_ROOT" && pwd)"
CORE_SRC="$WORKSPACE_ROOT/core/vauchi-core/src"

# Collision allow-list: `value:COUNT` per line (COUNT = exact number of
# known sites sharing this intentionally-reused info). '#' comments + blank
# lines ignored. CRYPTO_HYGIENE_ALLOWLIST overrides the path (self-test).
ALLOWLIST_FILE="${CRYPTO_HYGIENE_ALLOWLIST:-$SCRIPT_DIR/audit-crypto-hygiene.allowlist}"
[ -f "$ALLOWLIST_FILE" ] || ALLOWLIST_FILE="/dev/null"

# ── strip comment-only lines (input is `path:lineno:code`) ────────────
strip_comments() {
    grep -vE '^[^:]+:[0-9]+:[[:space:]]*(//|\*)' || true
}

# ── const map: BASENAME<TAB>NAME<TAB>VALUE, FILE-SCOPED (module-local) ─
build_const_map() {
    [ -d "$CORE_SRC" ] || return 0
    grep -rsoE '(const|static)[[:space:]]+[A-Z_][A-Z0-9_]*[^=]*=[[:space:]]*b"[^"]*"' \
        "$CORE_SRC" 2>/dev/null \
        | sed -E 's#^.*/([^/:]+):(const|static)[[:space:]]+([A-Z_][A-Z0-9_]*).*b"([^"]*)".*#\1\t\3\t\4#' \
        | sort -u || true
}

# ── HKDF derive/expand call sites (not definitions) ──────────────────
hkdf_call_sites() {
    [ -d "$CORE_SRC" ] || return 0
    grep -rsnE 'HKDF::(derive_key|expand)\(' "$CORE_SRC" 2>/dev/null \
        | strip_comments \
        | grep -vE 'fn[[:space:]]+(derive_key|expand)' \
        || true
}

# ── extractor (portable awk): empty / dup / unparsed ──────────────────
# shellcheck disable=SC2016  # awk program: single-quoted on purpose, the shell must NOT expand $0/$1/etc.
EXTRACT_AWK='
BEGIN {
    while ((getline l < cmap_file) > 0) {
        t1 = index(l, "\t"); if (t1 == 0) continue
        rest = substr(l, t1 + 1); t2 = index(rest, "\t"); if (t2 == 0) continue
        cmap[substr(l, 1, t1-1) SUBSEP substr(rest, 1, t2-1)] = substr(rest, t2+1)
    }
    while ((getline l < allow_file) > 0) {
        sub(/#.*/, "", l); gsub(/^[[:space:]]+|[[:space:]]+$/, "", l)
        if (l == "") continue
        ci = index(l, ":")
        if (ci > 0) { allow[substr(l, 1, ci-1)] = substr(l, ci+1) + 0 }
        else { allow[l] = 999999 }
    }
    empty = 0; unparsed = 0
}
{
    site = $0
    base = $0; sub(/:[0-9]+:.*/, "", base); sub(/.*\//, "", base)
    code = $0
    sub(/^[^:]+:[0-9]+:/, "", code)
    if (code ~ /derive_key\(/) { want = 3; start = index(code, "derive_key(") + 11 }
    else if (code ~ /expand\(/) { want = 2; start = index(code, "expand(") + 7 }
    else next

    depth = 1; instr = 0; n = 0; argstart = start
    for (i = start; i <= length(code); i++) {
        c = substr(code, i, 1)
        if (instr) { if (c == "\"") instr = 0; continue }
        if (c == "\"") { instr = 1; continue }
        if (c == "(") depth++
        else if (c == ",") { if (depth == 1) { a[++n] = substr(code, argstart, i - argstart); argstart = i + 1 } }
        else if (c == ")") { depth--; if (depth == 0) { a[++n] = substr(code, argstart, i - argstart); break } }
    }
    if (n < want) { unparsed++; print "  UNPARSED (multi-line?) call at: " site > "/dev/stderr"; next }
    info = a[want]
    gsub(/^[[:space:]]+|[[:space:]]+$/, "", info)

    if (info ~ /^b"[^"]*"$/) {
        val = info; sub(/^b"/, "", val); sub(/"$/, "", val)
        if (val == "") { empty++; print "  empty info at: " site > "/dev/stderr"; next }
        record(val, site)
    } else {
        ref = info; sub(/^&/, "", ref)
        if (ref ~ /^[A-Z_][A-Z0-9_]*$/) {
            key = base SUBSEP ref
            val = (key in cmap) ? cmap[key] : ("const:" ref)
            record(val, site)
        }
    }
    next
}
function record(v, s) {
    count[v]++
    if (count[v] == 1) firstsite[v] = s
    else if (count[v] == 2) seen[v] = "  " firstsite[v] "\n  " s
    else seen[v] = seen[v] "\n  " s
}
END {
    dup = 0
    for (v in count) {
        if (count[v] >= 2) {
            permitted = (v in allow) ? allow[v] : 0
            if (count[v] <= permitted) continue
            dup++
            note = (v in allow) ? (" EXCEEDS allow-listed count " permitted) : ""
            print "  duplicate info \"" v "\" at " count[v] " sites" note ":" > "/dev/stderr"
            print seen[v] > "/dev/stderr"
        }
    }
    print "empty\t" empty
    print "dup\t" dup
    print "unparsed\t" unparsed
}
'

CMAP_TMP="$(mktemp)"
trap 'rm -f "$CMAP_TMP"' EXIT
build_const_map > "$CMAP_TMP"

extract_out="$(hkdf_call_sites \
    | awk -v cmap_file="$CMAP_TMP" -v allow_file="$ALLOWLIST_FILE" "$EXTRACT_AWK")"
get_extract() { printf '%s\n' "$extract_out" | awk -F'\t' -v k="$1" '$1==k{print $2; exit}'; }
hkdf_empty_info="$(get_extract empty)";       hkdf_empty_info="${hkdf_empty_info:-0}"
hkdf_dup_info="$(get_extract dup)";           hkdf_dup_info="${hkdf_dup_info:-0}"
hkdf_unparsed_calls="$(get_extract unparsed)"; hkdf_unparsed_calls="${hkdf_unparsed_calls:-0}"

# ── raw HKDF outside the wrapper file (crypto/kdf.rs) ─────────────────
hkdf_raw_bypass() {
    [ -d "$CORE_SRC" ] || { printf '0'; return; }
    n=$(grep -rsnE 'Hkdf::<|hkdf::Hkdf|use[[:space:]]+hkdf' "$CORE_SRC" 2>/dev/null \
        | grep -vE '/kdf\.rs:' \
        | strip_comments \
        | grep -c '' || true)
    printf '%s' "${n:-0}"
}
hkdf_raw_bypass_n=$(hkdf_raw_bypass)

# ── Argon2 derivation with a literal (constant) salt ──────────────────
argon2_const_salt() {
    [ -d "$CORE_SRC" ] || { printf '0'; return; }
    n=$(grep -rsnE '(derive_key_argon2id|hash_password_into)\([^)]*b"' "$CORE_SRC" 2>/dev/null \
        | strip_comments \
        | grep -c '' || true)
    printf '%s' "${n:-0}"
}
argon2_const_salt_n=$(argon2_const_salt)

# ── A2: trust-level direct setters (ADR-034) ──────────────────────────
trust_setters() {
    [ -d "$CORE_SRC" ] || { printf '0'; return; }
    n=$(grep -rsnE 'fn[[:space:]]+set_trust_level|\.trust_level[[:space:]]*=[^=]' \
        "$CORE_SRC" 2>/dev/null \
        | strip_comments \
        | grep -vE 'set_trust_metrics' \
        | grep -c '' || true)
    printf '%s' "${n:-0}"
}
trust_level_setters=$(trust_setters)

crypto_hygiene_total=$((hkdf_empty_info + hkdf_dup_info + hkdf_raw_bypass_n \
    + hkdf_unparsed_calls + argon2_const_salt_n + trust_level_setters))

# ── render JSON ───────────────────────────────────────────────────────
captured_at=$(date -u +%Y-%m-%dT%H:%M:%SZ)
emit_json() {
    printf '{\n'
    printf '  "schema_version": 2,\n'
    printf '  "captured_at": "%s",\n' "$captured_at"
    printf '  "workspace_root": "%s",\n' "$WORKSPACE_ROOT"
    printf '  "totals": {\n'
    printf '    %-26s %d,\n' '"hkdf_empty_info":'      "$hkdf_empty_info"
    printf '    %-26s %d,\n' '"hkdf_dup_info":'        "$hkdf_dup_info"
    printf '    %-26s %d,\n' '"hkdf_raw_bypass":'      "$hkdf_raw_bypass_n"
    printf '    %-26s %d,\n' '"hkdf_unparsed_calls":'  "$hkdf_unparsed_calls"
    printf '    %-26s %d,\n' '"argon2_const_salt":'    "$argon2_const_salt_n"
    printf '    %-26s %d,\n' '"trust_level_setters":'  "$trust_level_setters"
    printf '    %-26s %d\n'  '"crypto_hygiene_total":' "$crypto_hygiene_total"
    printf '  }\n'
    printf '}\n'
}

if [ "$CHECK_MODE" -eq 0 ]; then
    emit_json
    exit 0
fi

# ── --check (ratchet) mode ────────────────────────────────────────────
# shellcheck disable=SC2016  # awk program: single-quoted on purpose.
baseline_value() {
    awk -v k="\"$1\"" '
        $1 ~ k { v = $0; sub(/.*:[[:space:]]+/, "", v); sub(/,$/, "", v); print v + 0; exit }
    ' "$BASELINE_FILE"
}

regressions=0
check_one() {
    name="$1"; current="$2"
    base=$(baseline_value "$name"); base="${base:-0}"
    if [ "$current" -gt "$base" ]; then
        printf 'REGRESSION %s: baseline %d, now %d\n' "$name" "$base" "$current" >&2
        regressions=$((regressions + 1))
    fi
}

check_one 'hkdf_empty_info'      "$hkdf_empty_info"
check_one 'hkdf_dup_info'        "$hkdf_dup_info"
check_one 'hkdf_raw_bypass'      "$hkdf_raw_bypass_n"
check_one 'hkdf_unparsed_calls'  "$hkdf_unparsed_calls"
check_one 'argon2_const_salt'    "$argon2_const_salt_n"
check_one 'trust_level_setters'  "$trust_level_setters"
check_one 'crypto_hygiene_total' "$crypto_hygiene_total"

if [ "$regressions" -gt 0 ]; then
    printf 'audit-crypto-hygiene: %d crypto-hygiene regression(s) above baseline %s\n' \
        "$regressions" "$BASELINE_FILE" >&2
    printf 'ADR-007 (HKDF domain separation) / ADR-034 (trust-level immutability). Fix the source.\n' >&2
    exit 1
fi

printf 'audit-crypto-hygiene: OK — all counts at or below baseline %s\n' "$BASELINE_FILE"
exit 0
