#!/usr/bin/env bash
# SPDX-FileCopyrightText: 2026 Mattia Egloff <mattia.egloff@pm.me>
#
# SPDX-License-Identifier: GPL-3.0-or-later
#
# Sentinel suite for scripts/check-vet-audits.sh — VSC01: a cargo-vet
# [[audits]] entry is a human attestation; AI-staged additions are
# blocked. Rule page: _private/docs/lint-errors/vsc01-no-ai-audits.md

set -u

SCRIPT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
SCRIPT="$SCRIPT_DIR/check-vet-audits.sh"

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

run_diff() { # $1=diff content → sets rc, out
    d="$(mktemp)"
    printf '%s\n' "$1" > "$d"
    out="$("$SCRIPT" --diff-file "$d" 2>&1)"; rc=$?
    rm -f "$d"
}

# ── added [[audits]] entry → blocked with VSC01 ────────────────────────
run_diff '--- a/supply-chain/audits.toml
+++ b/supply-chain/audits.toml
+[[audits.serde]]
+who = "Nobody <fake@example.com>"
+criteria = "safe-to-deploy"'
assert_eq "added audits: exit 1" "1" "$rc"
assert_eq "added audits: VSC01 in message" "1" \
    "$(printf '%s' "$out" | grep -q 'VSC01:' && echo 1 || echo 0)"
assert_eq "added audits: names the fix" "1" \
    "$(printf '%s' "$out" | grep -qE 'VSC01: .+ — fix: .+' && echo 1 || echo 0)"

# ── added [[exemptions]] entry → allowed ───────────────────────────────
run_diff '--- a/supply-chain/config.toml
+++ b/supply-chain/config.toml
+[[exemptions.serde]]
+version = "1.0.200"
+criteria = "safe-to-deploy"'
assert_eq "added exemption: exit 0" "0" "$rc"

# ── removing an audits entry → allowed ─────────────────────────────────
run_diff '--- a/supply-chain/audits.toml
+++ b/supply-chain/audits.toml
-[[audits.oldcrate]]
-who = "Someone <x@y.z>"'
assert_eq "removed audits: exit 0" "0" "$rc"

# ── human override env → allowed ───────────────────────────────────────
d="$(mktemp)"
printf '%s\n' '+[[audits.serde]]' > "$d"
out="$(VAUCHI_HUMAN_AUDIT=1 "$SCRIPT" --diff-file "$d" 2>&1)"; rc=$?
rm -f "$d"
assert_eq "human override: exit 0" "0" "$rc"

# ── empty diff → allowed ───────────────────────────────────────────────
run_diff ''
assert_eq "empty diff: exit 0" "0" "$rc"

# Exercise the default staged-diff path as well as the diff-file seam.
task_vet_root="$(mktemp -d)"
trap 'rm -rf "$task_vet_root"' EXIT
mkdir -p "$task_vet_root/repo/supply-chain" "$task_vet_root/bin"
git -C "$task_vet_root/repo" init -q
out="$(cd "$task_vet_root/repo" && "$SCRIPT" 2>&1)"; rc=$?
assert_eq "empty staged Git diff: exit 0" "0" "$rc"
printf '[[audits.probe]]\n' > "$task_vet_root/repo/supply-chain/audits.toml"
git -C "$task_vet_root/repo" add supply-chain/audits.toml
out="$(cd "$task_vet_root/repo" && "$SCRIPT" 2>&1)"; rc=$?
assert_eq "real staged audit addition: exit 1" "1" "$rc"

cat > "$task_vet_root/bin/git" <<'STUB'
#!/bin/sh
echo 'injected staged-diff failure' >&2
exit 2
STUB
chmod +x "$task_vet_root/bin/git"
out="$(cd "$task_vet_root/repo" && PATH="$task_vet_root/bin:$PATH" "$SCRIPT" 2>&1)"; rc=$?
assert_eq "failed staged diff: exit 2" "2" "$rc"
assert_eq "failed staged diff: error stays visible" "1" \
    "$(printf '%s\n' "$out" | grep -q 'injected staged-diff failure' && echo 1 || echo 0)"
out="$(cd "$task_vet_root/repo" && VAUCHI_HUMAN_AUDIT=1 PATH="$task_vet_root/bin:$PATH" "$SCRIPT" 2>&1)"; rc=$?
assert_eq "human override still bypasses staged-diff inspection" "0" "$rc"

# ── non-tautology guard (CC-21) ────────────────────────────────────────
stub="$(mktemp)"; printf '#!/bin/sh\nexit 0\n' > "$stub"; chmod +x "$stub"
d="$(mktemp)"; printf '+[[audits.serde]]\n' > "$d"
"$stub" --diff-file "$d" >/dev/null 2>&1; rc=$?
assert_eq "stub detector would be caught (exit != 1 detected)" "0" "$rc"
rm -f "$d" "$stub"

printf '\n%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
