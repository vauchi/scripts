#!/usr/bin/env bash
# SPDX-FileCopyrightText: 2026 Mattia Egloff <mattia.egloff@pm.me>
#
# SPDX-License-Identifier: GPL-3.0-or-later

# Sentinel regression suite for audit-frontend-domain-calls.sh — the
# Rust/C++/C# frontend Humble-UI domain-mutation ratchet (ADR-021/043).
#
# Per CC-20 / CC-21 these tests are NON-tautological: each builds a tiny
# synthetic frontend tree, plants known sentinel lines, runs the real
# script, and asserts the gate COUNTS domain-mutating calls and does NOT
# count the documented false-positive shapes:
#   - read queries (is_*/list_*/get_*/load_*) — frontends may read core
#   - a local binding (`let save_path = …`) with no leading `.`
#   - the word-start guard (`autosave(` must not match `save(`)
#   - the wrong file extension (a `.md`/`.txt` with `.save_x(`)
#   - excluded trees (target/, build/, tests/)
# It also asserts the --check ratchet exits nonzero ABOVE baseline and
# zero AT/BELOW baseline.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
SCRIPT="$SCRIPT_DIR/../audit-frontend-domain-calls.sh"

pass=0
fail=0

assert_eq() {
    name="$1"; want="$2"; got="$3"
    if [ "$want" = "$got" ]; then
        printf '  PASS %s\n' "$name"
        pass=$((pass + 1))
    else
        printf '  FAIL %s\n    want: %s\n    got:  %s\n' "$name" "$want" "$got" >&2
        fail=$((fail + 1))
    fi
}

extract_counter() {
    printf '%s' "$1" | awk -v k="\"$2\"" '
        $1 ~ k {
            v = $0
            sub(/.*:[[:space:]]+/, "", v)
            sub(/,$/, "", v)
            print v
            exit
        }
    '
}

# ── 1. Empty workspace → all zero, valid JSON, exit 0 ─────────────────
test_empty_workspace() {
    root=$(mktemp -d)
    out=$("$SCRIPT" "$root"); rc=$?
    assert_eq "empty: exit 0" 0 "$rc"
    assert_eq "empty: tui == 0"     "0" "$(extract_counter "$out" domain_calls_tui)"
    assert_eq "empty: windows == 0" "0" "$(extract_counter "$out" domain_calls_windows)"
    assert_eq "empty: total == 0"   "0" "$(extract_counter "$out" domain_calls_total)"
    rm -rf "$root"
}

# ── 2. Rust sentinel (tui) — counts mutating calls + type construction ─
# 3 true positives:
#   .save_duress_settings(  .configure_emergency_broadcast(  vauchi_core::types::
# False positives that must NOT count:
#   .is_duress_enabled()  — read query verb not in the mutating list
#   .list_groups()        — read query
#   let save_path = …     — local binding, no leading `.`
#   .get_card()           — read query
test_rust_sentinel() {
    root=$(mktemp -d)
    dir="$root/tui/src/handlers"
    mkdir -p "$dir"
    cat >"$dir/duress.rs" <<'RS'
fn handle() {
    wb.save_duress_settings(&settings).unwrap();
    wb.configure_emergency_broadcast(ids, msg, loc)?;
    let s = vauchi_core::types::DuressSettings { pin };
    // false positives below must NOT count
    let enabled = wb.is_duress_enabled();
    let groups = wb.list_groups();
    let save_path = format!("/tmp/x");
    let card = wb.get_card();
}
RS
    out=$("$SCRIPT" "$root")
    assert_eq "rust: counts 3 mutating/construction lines" \
        "3" "$(extract_counter "$out" domain_calls_tui)"
    rm -rf "$root"
}

# ── 3. C++ sentinel (linux-qt) — verb call, word-start guarded ────────
# 1 true positive: saveBackupToFile(
# False positives: autosaveTimer( (word-start guard), loadConfig( (read),
# a local `int save_count = 0;` (no call paren adjacency to a verb).
test_cpp_sentinel() {
    root=$(mktemp -d)
    dir="$root/linux-qt/src/coreui"
    mkdir -p "$dir"
    cat >"$dir/screenrenderer.cpp" <<'CPP'
void Renderer::run() {
    saveBackupToFile(path);
    // false positives below must NOT count
    autosaveTimer(1000);
    loadConfig();
    int save_count = 0;
}
CPP
    out=$("$SCRIPT" "$root")
    assert_eq "cpp: counts 1 verb call, skips autosave/load/local" \
        "1" "$(extract_counter "$out" domain_calls_linux_qt)"
    rm -rf "$root"
}

# ── 4. C# sentinel (windows) — PascalCase verb call, guarded ──────────
# 1 true positive: SaveWindowState(
# False positives: AutoSaveState( (word-start guard), LoadState( (read).
test_cs_sentinel() {
    root=$(mktemp -d)
    dir="$root/windows/Vauchi"
    mkdir -p "$dir"
    cat >"$dir/MainWindow.xaml.cs" <<'CS'
public void Run() {
    SaveWindowState();
    // false positives below must NOT count
    AutoSaveState();
    LoadState();
}
CS
    out=$("$SCRIPT" "$root")
    assert_eq "cs: counts 1 PascalCase verb call, skips AutoSave/Load" \
        "1" "$(extract_counter "$out" domain_calls_windows)"
    rm -rf "$root"
}

# ── 5. Wrong extension does NOT count ─────────────────────────────────
# A doc/text file under a Rust src tree carrying `.save_x(` must be
# ignored by the `\.rs:` path filter.
test_wrong_extension() {
    root=$(mktemp -d)
    dir="$root/cli/src"
    mkdir -p "$dir"
    cat >"$dir/notes.md" <<'MD'
The handler calls wb.save_local_identity(&id) — documentation only.
MD
    cat >"$dir/real.rs" <<'RS'
fn h() { wb.save_local_identity(&id)?; }
RS
    out=$("$SCRIPT" "$root")
    assert_eq "ext: only the .rs hit counts, not the .md" \
        "1" "$(extract_counter "$out" domain_calls_cli)"
    rm -rf "$root"
}

# ── 6. Excluded trees do NOT contribute ───────────────────────────────
# target/, build/, tests/ may carry domain calls (build artifacts, test
# fixtures) — none must count.
test_excluded_paths() {
    root=$(mktemp -d)
    real="$root/tui/src"
    targ="$root/tui/src/target/debug"
    tdir="$root/tui/src/tests"
    mkdir -p "$real" "$targ" "$tdir"
    cat >"$real/main.rs" <<'RS'
fn h() { wb.save_key(&k, v)?; }
RS
    cat >"$targ/gen.rs" <<'RS'
fn g() { wb.configure_emergency_broadcast(a, b, c)?; }
RS
    cat >"$tdir/it.rs" <<'RS'
fn t() { wb.setup_app_password(p)?; }
RS
    out=$("$SCRIPT" "$root")
    assert_eq "excluded: only the 1 real hit counts" \
        "1" "$(extract_counter "$out" domain_calls_tui)"
    rm -rf "$root"
}

# ── 7. Total sums across repos ────────────────────────────────────────
test_total_sums() {
    root=$(mktemp -d)
    mkdir -p "$root/tui/src" "$root/windows/Vauchi"
    cat >"$root/tui/src/main.rs" <<'RS'
fn h() {
    wb.save_key(&k, v)?;
    wb.setup_app_password(p)?;
}
RS
    cat >"$root/windows/Vauchi/Win.xaml.cs" <<'CS'
void R() { SaveWindowState(); }
CS
    out=$("$SCRIPT" "$root")
    assert_eq "total: 2 tui + 1 windows == 3" \
        "3" "$(extract_counter "$out" domain_calls_total)"
    rm -rf "$root"
}

# ── 8. --check ratchet: exits nonzero ABOVE baseline ──────────────────
test_check_above_baseline_fails() {
    root=$(mktemp -d)
    mkdir -p "$root/tui/src"
    cat >"$root/tui/src/main.rs" <<'RS'
fn h() {
    wb.save_key(&k, v)?;
    wb.setup_app_password(p)?;
}
RS
    base="$root/baseline.json"
    cat >"$base" <<'JSON'
{
  "totals": {
    "domain_calls_tui": 1,
    "domain_calls_total": 1
  }
}
JSON
    set +e
    "$SCRIPT" --check "$base" "$root" >/dev/null 2>&1
    rc=$?
    set -e
    assert_eq "check: exit 1 when count exceeds baseline" "1" "$rc"
    rm -rf "$root"
}

# ── 9. --check ratchet: exits zero AT/BELOW baseline ──────────────────
test_check_at_or_below_baseline_passes() {
    root=$(mktemp -d)
    mkdir -p "$root/tui/src"
    cat >"$root/tui/src/main.rs" <<'RS'
fn h() {
    wb.save_key(&k, v)?;
    wb.setup_app_password(p)?;
}
RS
    base_at="$root/at.json"
    cat >"$base_at" <<'JSON'
{
  "totals": {
    "domain_calls_tui": 2,
    "domain_calls_total": 2
  }
}
JSON
    base_below="$root/below.json"
    cat >"$base_below" <<'JSON'
{
  "totals": {
    "domain_calls_tui": 9,
    "domain_calls_total": 9
  }
}
JSON
    set +e
    "$SCRIPT" --check "$base_at" "$root" >/dev/null 2>&1; rc_at=$?
    "$SCRIPT" --check "$base_below" "$root" >/dev/null 2>&1; rc_below=$?
    set -e
    assert_eq "check: exit 0 at baseline" "0" "$rc_at"
    assert_eq "check: exit 0 below baseline" "0" "$rc_below"
    rm -rf "$root"
}

# ── 10. --check missing baseline → exit 2 ─────────────────────────────
test_check_missing_baseline() {
    root=$(mktemp -d)
    set +e
    "$SCRIPT" --check "/does/not/exist/$$.json" "$root" >/dev/null 2>&1
    rc=$?
    set -e
    assert_eq "check: missing baseline → exit 2" "2" "$rc"
    rm -rf "$root"
}

# ── 11. JSON output parses ────────────────────────────────────────────
test_json_validity() {
    root=$(mktemp -d)
    out=$("$SCRIPT" "$root")
    if printf '%s' "$out" | python3 -m json.tool >/dev/null 2>&1; then
        printf '  PASS json: parses as JSON\n'; pass=$((pass + 1))
    else
        printf '  FAIL json: invalid JSON\n    output: %s\n' "$out" >&2
        fail=$((fail + 1))
    fi
    rm -rf "$root"
}

# ── 12. Bad workspace root → exit 2 ───────────────────────────────────
test_bad_workspace() {
    set +e
    "$SCRIPT" "/does/not/exist/$$" >/dev/null 2>&1
    rc=$?
    set -e
    assert_eq "bad workspace: exit 2" "2" "$rc"
}

# ── 13. VRS02: form-factor BRANCHES count; construction params do not ─
# ADR-043: frontends never branch on form factor. Passing DisplayHint
# to an engine constructor is the sanctioned use and must NOT count.
test_form_factor_rust_sentinel() {
    root=$(mktemp -d)
    mkdir -p "$root/tui/src"
    cat >"$root/tui/src/screen.rs" <<'RS'
fn render() {
    if hint == DisplayHint::Watch { compact() }
    if matches!(h, DisplayHint::Phone) { phone() }
    // sanctioned uses below must NOT count
    let engine = AppEngine::new(DisplayHint::Desktop);
    let hint = DisplayHint::Desktop;
}
RS
    out=$("$SCRIPT" "$root")
    assert_eq "vrs02 rust: counts 2 branch lines" \
        "2" "$(extract_counter "$out" form_factor_tui)"
    assert_eq "vrs02 rust: total == 2" \
        "2" "$(extract_counter "$out" form_factor_total)"
    rm -rf "$root"
}

# ── 14. VRS02: empty workspace has zeroed form-factor counters ─────────
test_form_factor_empty() {
    root=$(mktemp -d)
    out=$("$SCRIPT" "$root")
    assert_eq "vrs02 empty: form_factor_total == 0" \
        "0" "$(extract_counter "$out" form_factor_total)"
    rm -rf "$root"
}

# ── 15. VRS02: ratchet fires when a branch appears over baseline 0 ─────
test_form_factor_ratchet() {
    root=$(mktemp -d)
    mkdir -p "$root/windows/Vauchi"
    cat >"$root/windows/Vauchi/Shell.cs" <<'CS'
void Render() {
    if (Model.Hint == DisplayHint.Watch) { Compact(); }
}
CS
    base="$root/baseline.json"
    cat >"$base" <<'JSON'
{
  "totals": {
    "form_factor_windows": 0,
    "form_factor_total": 0
  }
}
JSON
    set +e
    out=$("$SCRIPT" --check "$base" "$root" 2>&1)
    rc=$?
    set -e
    assert_eq "vrs02 ratchet: exit 1 above baseline" "1" "$rc"
    rm -rf "$root"
}

# ── run ───────────────────────────────────────────────────────────────
test_empty_workspace
test_rust_sentinel
test_cpp_sentinel
test_cs_sentinel
test_wrong_extension
test_excluded_paths
test_total_sums
test_check_above_baseline_fails
test_check_at_or_below_baseline_passes
test_check_missing_baseline
test_json_validity
test_bad_workspace
test_form_factor_rust_sentinel
test_form_factor_empty
test_form_factor_ratchet

printf '\n%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
