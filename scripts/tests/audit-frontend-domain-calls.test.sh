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
#   .save_exchanged_contact() — atomic core API, not frontend mutation logic
#   .save_key() — SecureStorage adapter operation
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
    wb.save_exchanged_contact(&contact, &ratchet, true)?;
    keyring.save_key("probe", bytes)?;
}
RS
    out=$("$SCRIPT" "$root")
    assert_eq "rust: counts 3 mutating/construction lines" \
        "3" "$(extract_counter "$out" domain_calls_tui)"
    rm -rf "$root"
}

# ── 3. C++ sentinel (linux-qt) — verb call, word-start guarded ────────
# 1 true positive: validateContact(
# False positives: autosaveTimer( (word-start guard), loadConfig( (read),
# saveBackupToFile( (native file adapter), and a local `int save_count = 0;`.
test_cpp_sentinel() {
    root=$(mktemp -d)
    dir="$root/linux-qt/src/coreui"
    mkdir -p "$dir"
    cat >"$dir/screenrenderer.cpp" <<'CPP'
void Renderer::run() {
    validateContact(payload);
    // false positives below must NOT count
    autosaveTimer(1000);
    loadConfig();
    saveBackupToFile(path);
    int save_count = 0;
}
CPP
    out=$("$SCRIPT" "$root")
    assert_eq "cpp: counts 1 verb call, skips autosave/load/local" \
        "1" "$(extract_counter "$out" domain_calls_linux_qt)"
    rm -rf "$root"
}

# ── 3b. Native image export is renderer I/O, not a domain mutation ───
# Render-fixture tools exercise the real native renderer and persist its
# pixels for visual comparison. Rust GDK and Qt image APIs happen to use
# the broad `save*` spelling, but neither call changes Vauchi domain state.
test_native_image_export_not_counted() {
    root=$(mktemp -d)
    mkdir -p "$root/linux-gtk/src/bin" "$root/linux-qt/src"
    cat >"$root/linux-gtk/src/bin/render_fixture.rs" <<'RS'
fn render(texture: Texture) {
    let png = texture.save_to_png_bytes();
}
RS
    cat >"$root/linux-qt/src/main.cpp" <<'CPP'
void render(const QPixmap &pixmap, const QString &path) {
    pixmap.save(path);
}
CPP
    cat >"$root/linux-qt/src/display_abi.cpp" <<'CPP'
void snapshotIfAsked() {
    grab().save(QString::fromUtf8(path));
}
CPP
    out=$("$SCRIPT" "$root")
    assert_eq "native image export: gtk == 0" \
        "0" "$(extract_counter "$out" domain_calls_linux_gtk)"
    assert_eq "native image export: qt == 0" \
        "0" "$(extract_counter "$out" domain_calls_linux_qt)"
    rm -rf "$root"
}

# ── 4. C# sentinel (windows) — PascalCase verb call, guarded ──────────
# 1 true positive: ConfigureEmergency(
# False positives: AutoSaveState( (word-start guard), LoadState( (read),
# SaveWindowState( (presentation persistence).
test_cs_sentinel() {
    root=$(mktemp -d)
    dir="$root/windows/Vauchi"
    mkdir -p "$dir"
    cat >"$dir/MainWindow.xaml.cs" <<'CS'
public void Run() {
    ConfigureEmergency();
    // false positives below must NOT count
    AutoSaveState();
    LoadState();
    SaveWindowState();
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
fn h() { wb.save_duress_settings(&settings)?; }
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

# ── 6b. `*_tests.rs` siblings are test code, not frontend calls ───────
# The repo gates these with `#[cfg(test)]` on the `#[path] mod` line in
# the PARENT module, so the attribute is in a different file and the
# cfg(test) state machine cannot see it. Before this exclusion, one
# `setup_app_password` in tui/src/ui/presentation_renderer_tests.rs
# counted as a frontend domain call and held the ratchet red.
test_sibling_test_files_excluded() {
    root=$(mktemp -d)
    src="$root/tui/src/ui"
    mkdir -p "$src"
    cat >"$src/renderer.rs" <<'RS'
fn draw() { wb.save_duress_settings(&settings)?; }
RS
    cat >"$src/renderer_tests.rs" <<'RS'
fn arrange() { wb.setup_app_password("app-password-123")?; }
RS
    out=$("$SCRIPT" "$root")
    assert_eq "sibling tests: only the production call counts" \
        "1" "$(extract_counter "$out" domain_calls_tui)"

    # The exclusion must not become a way to hide production code: a real
    # call in a normally-named file next to it is still counted.
    cat >"$src/more.rs" <<'RS'
fn also() { wb.configure_emergency_broadcast(a, b, c)?; }
RS
    out=$("$SCRIPT" "$root")
    assert_eq "sibling tests: a second production call still counts" \
        "2" "$(extract_counter "$out" domain_calls_tui)"
    rm -rf "$root"
}

# ── 7. Total sums across repos ────────────────────────────────────────
test_total_sums() {
    root=$(mktemp -d)
    mkdir -p "$root/tui/src" "$root/windows/Vauchi"
    cat >"$root/tui/src/main.rs" <<'RS'
fn h() {
    wb.configure_emergency_broadcast(a, b, c)?;
    wb.setup_app_password(p)?;
}
RS
    cat >"$root/windows/Vauchi/Win.xaml.cs" <<'CS'
void R() { ValidateContact(); }
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
    wb.configure_emergency_broadcast(a, b, c)?;
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

# ── 8b. per-repo baseline overrides the shared file ───────────────────
# A baseline that lives in the repo it measures can be lowered in the
# same MR as the removal that earns it. The shared file cannot: it lives
# in `scripts` while the code lives in `cli`, so the two are separate
# MRs and can merge in the wrong order (scripts!510).
test_per_repo_baseline_overrides_shared() {
    root=$(mktemp -d)
    mkdir -p "$root/cli/src"
    cat >"$root/cli/src/main.rs" <<'RS'
fn h() {
    wb.setup_app_password(p)?;
    wb.setup_duress_password(d)?;
}
RS
    base="$root/baseline.json"
    cat >"$base" <<'JSON'
{
  "totals": {
    "domain_calls_cli": 5,
    "domain_calls_total": 5
  }
}
JSON
    # The repo declares a tighter budget than the shared file allows.
    cat >"$root/cli/.audit-baseline.json" <<'JSON'
{
  "domain_calls": 1
}
JSON
    set +e
    out=$("$SCRIPT" --check "$base" "$root" 2>&1)
    rc=$?
    set -e
    assert_eq "per-repo baseline wins over the shared file" "1" "$rc"
    case "$out" in
        *"baseline 1, now 2"*) got="reported" ;;
        *) got="not reported: $out" ;;
    esac
    assert_eq "per-repo regression names the repo's own budget" "reported" "$got"
    rm -rf "$root"
}

# ── 8c. shared file still applies when the repo declares nothing ───────
test_shared_baseline_used_without_per_repo_file() {
    root=$(mktemp -d)
    mkdir -p "$root/cli/src"
    cat >"$root/cli/src/main.rs" <<'RS'
fn h() {
    wb.setup_app_password(p)?;
    wb.setup_duress_password(d)?;
}
RS
    base="$root/baseline.json"
    cat >"$base" <<'JSON'
{
  "totals": {
    "domain_calls_cli": 5,
    "domain_calls_total": 5
  }
}
JSON
    set +e
    "$SCRIPT" --check "$base" "$root" >/dev/null 2>&1
    rc=$?
    set -e
    assert_eq "shared baseline still honoured (migration is opt-in)" "0" "$rc"
    rm -rf "$root"
}

# ── 8d. the aggregate follows the per-repo budgets ─────────────────────
# The recorded `_total` is derivable: it equals the sum of its
# components, so it must not silently permit what a component forbids.
test_total_follows_per_repo_baselines() {
    root=$(mktemp -d)
    mkdir -p "$root/cli/src"
    cat >"$root/cli/src/main.rs" <<'RS'
fn h() {
    wb.setup_app_password(p)?;
    wb.setup_duress_password(d)?;
}
RS
    base="$root/baseline.json"
    # Shared file is permissive on BOTH the component and the total.
    cat >"$base" <<'JSON'
{
  "totals": {
    "domain_calls_cli": 9,
    "domain_calls_total": 9
  }
}
JSON
    cat >"$root/cli/.audit-baseline.json" <<'JSON'
{
  "domain_calls": 0
}
JSON
    set +e
    out=$("$SCRIPT" --check "$base" "$root" 2>&1)
    rc=$?
    set -e
    assert_eq "total cannot exceed the summed per-repo budgets" "1" "$rc"
    case "$out" in
        *domain_calls_total*) got="total reported" ;;
        *) got="total silent: $out" ;;
    esac
    assert_eq "total regression is reported too" "total reported" "$got"
    rm -rf "$root"
}

# ── 9. --check ratchet: exits zero AT/BELOW baseline ──────────────────
test_check_at_or_below_baseline_passes() {
    root=$(mktemp -d)
    mkdir -p "$root/tui/src"
    cat >"$root/tui/src/main.rs" <<'RS'
fn h() {
    wb.configure_emergency_broadcast(a, b, c)?;
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

# ── 16. Rust inline #[cfg(test)] modules do NOT count ──────────────────
# The /tests/ tree exclusion already keeps test fixtures out of the
# baseline; Rust's inline `#[cfg(test)] mod tests` idiom is the same
# category. Lines after the first `#[cfg(test)]` attribute in a .rs file
# must not move the ratchet; production lines above it still count.
test_rust_inline_test_module_excluded() {
    root=$(mktemp -d)
    dir="$root/cli/src"
    mkdir -p "$dir"
    cat >"$dir/handler.rs" <<'RS'
fn handle() {
    wb.save_duress_settings(&settings).unwrap();
}

// INLINE_TEST_REQUIRED: Binary crate without lib.rs - tests cannot be external
#[cfg(test)]
mod tests {
    fn setup() {
        wb.setup_app_password(p).unwrap();
        wb.save_local_identity(&id).unwrap();
    }
}
RS
    out=$("$SCRIPT" "$root")
    assert_eq "rust inline tests: only the production line counts" \
        "1" "$(extract_counter "$out" domain_calls_cli)"
    rm -rf "$root"
}

# ── 17. A cfg(test) that is NOT a test module must NOT blind the file ──
# `#[cfg(test)] use …;` at column 0 (real shape: cli/src/ui/presentation.rs)
# is a test-only import, not a module. Everything below it is production
# code and must still be audited — for BOTH counter families.
test_cfg_test_use_does_not_blind_file() {
    root=$(mktemp -d)
    dir="$root/cli/src"
    mkdir -p "$dir"
    cat >"$dir/presentation.rs" <<'RS'
// test-only protocol accessor import
#[cfg(test)]
use vauchi_core::Event;

fn render() {
    wb.save_duress_settings(&settings).unwrap();
    if hint == DisplayHint::Watch { compact() }
}
RS
    out=$("$SCRIPT" "$root")
    assert_eq "cfg(test) use: production domain call still counts" \
        "1" "$(extract_counter "$out" domain_calls_cli)"
    assert_eq "cfg(test) use: production form-factor branch still counts" \
        "1" "$(extract_counter "$out" form_factor_cli)"
    rm -rf "$root"
}

# ── 18. An indented (impl-level) cfg(test) must NOT blind the file ─────
# Test-only helper methods inside a production impl carry an indented
# attribute (real shape: tui/src/ui/presentation_protocol.rs). Only a
# column-0 attribute opening a `mod` may start the skip region.
test_indented_cfg_test_does_not_blind_file() {
    root=$(mktemp -d)
    dir="$root/tui/src"
    mkdir -p "$dir"
    cat >"$dir/engine.rs" <<'RS'
impl Engine {
    fn render(&self) { draw(); }

    #[cfg(test)]
    fn test_helper(&self) { wb.setup_app_password(p).unwrap(); }

    fn production(&self) {
        wb.save_duress_settings(&settings).unwrap();
    }
}
RS
    out=$("$SCRIPT" "$root")
    # 2, not 1: the impl-level test helper's body still counts — the
    # heuristic only skips mod-wrapped regions, so non-module test code
    # is over-counted (safe direction). The assertion that matters is
    # that the production call BELOW the attribute is not blinded.
    assert_eq "indented cfg(test): production call after it still counts" \
        "2" "$(extract_counter "$out" domain_calls_tui)"
    rm -rf "$root"
}

# ── 19. cfg(test) followed by a non-mod item is a false alarm ──────────
# The skip decision looks at the next non-attribute line: only a `mod`
# declaration opens a test region. A cfg(test) free function at column 0
# keeps the rest of the file audited.
test_cfg_test_free_function_does_not_blind_file() {
    root=$(mktemp -d)
    dir="$root/cli/src"
    mkdir -p "$dir"
    cat >"$dir/util.rs" <<'RS'
fn production_one() {
    wb.save_duress_settings(&settings).unwrap();
}

#[cfg(test)]
fn helper() {
    wb.setup_app_password(p).unwrap();
}

fn production_two() {
    wb.configure_emergency_broadcast(a, b, c).unwrap();
}
RS
    out=$("$SCRIPT" "$root")
    # 3, not 2: the cfg(test) free function's body counts too (over-count,
    # safe direction — only mod-wrapped regions are skipped). The critical
    # assertion is that production_two, BELOW the attribute, still counts.
    assert_eq "cfg(test) fn: production calls count, fn body over-counts" \
        "3" "$(extract_counter "$out" domain_calls_cli)"
    rm -rf "$root"
}

# ── 20. Run as `sh`, a shell without a match still reports ───────────
# ci-templates/domain-calls.yml runs the audit with `sh` (busybox ash on
# alpine). There errexit and pipefail reach into `$(...)`, so a grep that
# matches nothing must not end the run: the C# and C++ shells have no
# form-factor branch, and the audit has to say 0, not exit silently.
# `bash --posix` has the same errexit rule on every runner; a bare `sh`
# does not: on node:20 it is dash, which rejects `set -o pipefail` first.
test_sh_run_with_no_match_reports() {
    root=$(mktemp -d)
    mkdir -p "$root/windows/Vauchi" "$root/linux-qt/src"
    printf 'public void Run() { LoadState(); }\n' >"$root/windows/Vauchi/App.cs"
    printf 'void f() { load(); }\n' >"$root/linux-qt/src/app.cpp"
    out=$(bash --posix "$SCRIPT" "$root" 2>&1) || true
    assert_eq "sh: windows form_factor reported" \
        "0" "$(extract_counter "$out" form_factor_windows)"
    assert_eq "sh: linux_qt form_factor reported" \
        "0" "$(extract_counter "$out" form_factor_linux_qt)"
    rm -rf "$root"
}

# ── run ───────────────────────────────────────────────────────────────
test_empty_workspace
test_rust_sentinel
test_cpp_sentinel
test_native_image_export_not_counted
test_cs_sentinel
test_wrong_extension
test_excluded_paths
test_sibling_test_files_excluded
test_total_sums
test_check_above_baseline_fails
test_per_repo_baseline_overrides_shared
test_shared_baseline_used_without_per_repo_file
test_total_follows_per_repo_baselines
test_check_at_or_below_baseline_passes
test_check_missing_baseline
test_json_validity
test_bad_workspace
test_form_factor_rust_sentinel
test_form_factor_empty
test_form_factor_ratchet
test_rust_inline_test_module_excluded
test_cfg_test_use_does_not_blind_file
test_indented_cfg_test_does_not_blind_file
test_cfg_test_free_function_does_not_blind_file
test_sh_run_with_no_match_reports

printf '\n%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
