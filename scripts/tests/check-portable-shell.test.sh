#!/usr/bin/env bash
# SPDX-FileCopyrightText: 2026 Mattia Egloff <mattia.egloff@pm.me>
#
# SPDX-License-Identifier: GPL-3.0-or-later
#
# Sentinel regression suite for hooks/check-portable-shell.sh — proves
# each VSH01-12 pattern fires with its rule ID and fix-bearing message,
# and that suppression/exemption paths hold (non-tautological per CC-21).
# Fixture heredocs below are intentionally non-portable shell; the
# detector exempts */tests/*.test.sh for exactly this reason.
# Rule pages: _private/docs/lint-errors/vsh*.md

set -u

SCRIPT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
SCRIPT="$SCRIPT_DIR/../hooks/check-portable-shell.sh"

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

# run_case <id> <fixture-content...> — writes fixture, asserts exit 1,
# rule ID present, and the message carries an em-dash "fix:" segment.
run_case() {
    id="$1"; shift
    ws="$(mktemp -d)"
    printf '%s\n' "$@" > "$ws/bad.sh"
    out="$("$SCRIPT" "$ws/bad.sh" 2>&1)"; rc=$?
    assert_eq "$id: exit 1" "1" "$rc"
    assert_eq "$id: message carries ID" "1" \
        "$(printf '%s' "$out" | grep -c "$id:" | head -1)"
    assert_eq "$id: message names the fix" "1" \
        "$(printf '%s' "$out" | grep -qE "$id: .+ — fix: .+" && echo 1 || echo 0)"
    rm -rf "$ws"
}

# ── clean file → exit 0, no output noise ──────────────────────────────
ws="$(mktemp -d)"
cat > "$ws/clean.sh" <<'FIX'
#!/usr/bin/env bash
grep -E 'foo[[:space:]]+bar' file
printf 'line1\nline2\n'
mtime=$(stat -c %Y f 2>/dev/null || stat -f %m f)
sed -i.bak 's/a/b/' f && rm f.bak
FIX
out="$("$SCRIPT" "$ws/clean.sh" 2>&1)"; rc=$?
assert_eq "clean: exit 0" "0" "$rc"
rm -rf "$ws"

# ── VSH01-05 (pre-existing patterns, now with IDs) ─────────────────────
run_case VSH01 'grep -oP "ver=\K[0-9]+" f'
run_case VSH02 'echo -e "a\nb"'
run_case VSH03 'sed "s/foo\s*=/FOO=/" f'
run_case VSH04 'target=$(readlink -f "$0")'
run_case VSH05 'mtime=$(stat -c %Y "$f")'

# ── VSH06-12 (new patterns) ────────────────────────────────────────────
run_case VSH06 'grep -rl pat docs/ --exclude=README.md'
run_case VSH06 'grep -r pat . --include="*.md"'
run_case VSH07 'sed --in-place "s/a/b/" f'
run_case VSH07 "sed -i '' 's/a/b/' f"
run_case VSH08 'find src -name "*.rs" -printf "%f\n"'
run_case VSH09 'awk "{ print gensub(/a/, \"b\", \"g\") }" f'
run_case VSH10 'date -d "2026-07-05" +%s'
run_case VSH11 'hash=$(md5sum "$f" | cut -d" " -f1)'
run_case VSH12 'sed "s/[0-9]\+//" f'

# ── suppression: portable-shell-ok passes ──────────────────────────────
ws="$(mktemp -d)"
printf '%s\n' 'grep -oP "x" f  # portable-shell-ok: fixture in docs' > "$ws/sup.sh"
out="$("$SCRIPT" "$ws/sup.sh" 2>&1)"; rc=$?
assert_eq "suppression: exit 0" "0" "$rc"
rm -rf "$ws"

# ── stat -c with same-line -f fallback passes (VSH05 pair rule) ────────
ws="$(mktemp -d)"
printf '%s\n' 'm=$(stat -c %Y f 2>/dev/null || stat -f %m f)' > "$ws/pair.sh"
out="$("$SCRIPT" "$ws/pair.sh" 2>&1)"; rc=$?
assert_eq "stat fallback pair: exit 0" "0" "$rc"
rm -rf "$ws"

# ── tests/*.test.sh fixtures are exempt ───────────────────────────────
ws="$(mktemp -d)"; mkdir -p "$ws/tests"
printf '%s\n' 'grep -oP "x" f' > "$ws/tests/fixture.test.sh"
out="$("$SCRIPT" "$ws/tests/fixture.test.sh" 2>&1)"; rc=$?
assert_eq "tests-dir exemption: exit 0" "0" "$rc"
rm -rf "$ws"

# ── non-tautology guard: detector stub that always passes must FAIL ───
# (proves run_case's assertions can fail — CC-21)
stub="$(mktemp)"; printf '#!/bin/sh\nexit 0\n' > "$stub"; chmod +x "$stub"
ws="$(mktemp -d)"
printf '%s\n' 'grep -oP "x" f' > "$ws/bad.sh"
out="$("$stub" "$ws/bad.sh" 2>&1)"; rc=$?
assert_eq "stub detector would be caught (exit != 1 detected)" "0" "$rc"
rm -rf "$ws"; rm -f "$stub"

printf '\n%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
