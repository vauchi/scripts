#!/usr/bin/env bash
# SPDX-FileCopyrightText: 2026 Mattia Egloff <mattia.egloff@pm.me>
#
# SPDX-License-Identifier: GPL-3.0-or-later

# Sentinel regression suite for humble_check.py — the cross-language
# Humble UI ratchet (ADR-043 Amendment 6).
#
# Builds synthetic frontend trees, plants known sentinel lines, runs the
# real script, and asserts the ratchet counts violations, respects
# TODO(HUMBLE) / HUMBLE-EXCEPTION markers, and fails --check when a count
# rises above the baseline.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
SCRIPT="$SCRIPT_DIR/../humble_check.py"
CONFIG="$SCRIPT_DIR/../humble_check_rules.json"
BASELINE="$SCRIPT_DIR/../humble_check.baseline.json"
CROSS_CUTTING_TEMPLATE="$SCRIPT_DIR/../../ci-templates/cross-cutting-lint.yml"
PRE_PUSH="$SCRIPT_DIR/../../hooks/pre-push"
SCRIPTS_CI="$SCRIPT_DIR/../../.gitlab-ci.yml"

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

# extract_counter <json> <rule>
extract_counter() {
    printf '%s' "$1" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d['totals'].get('$2',0))"
}

# test_empty_workspace — no source → zero counts and valid JSON
test_empty_workspace() {
    root=$(mktemp -d)
    out=$(python3 "$SCRIPT" --repo ios --workspace-root "$root" --config "$CONFIG"); rc=$?
    assert_eq "empty: exit 0" 0 "$rc"
    assert_eq "empty: ios action_id_minting == 0" "0" "$(extract_counter "$out" action_id_minting)"
    assert_eq "empty: ios domain_screen_id_branch == 0" "0" "$(extract_counter "$out" domain_screen_id_branch)"
    rm -rf "$root"
}

test_android_display_module_keeps_rules() {
    root=$(mktemp -d)
    repo="$root/android"
    mkdir -p "$repo/app/src/main/kotlin" "$repo/display/src/main/kotlin"
    printf 'include(":app", ":display")\n' >"$repo/settings.gradle.kts"
    printf 'val prepared = true\n' >"$repo/app/src/main/kotlin/Host.kt"
    printf 'val action = "edit_avatar"\n' >"$repo/display/src/main/kotlin/BadView.kt"
    out=$(python3 "$SCRIPT" --repo android --repo-path "$repo" --config "$CONFIG")
    assert_eq "Android display action id minting is scanned" 1 "$(extract_counter "$out" action_id_minting)"

    rm "$repo/display/src/main/kotlin/BadView.kt"
    set +e
    python3 "$SCRIPT" --repo android --repo-path "$repo" --config "$CONFIG" >/dev/null 2>&1
    got=$?
    set -e
    assert_eq "empty declared Android display sources fail" 2 "$got"
    rm -rf "$repo/display"
    set +e
    python3 "$SCRIPT" --repo android --repo-path "$repo" --config "$CONFIG" >/dev/null 2>&1
    got=$?
    set -e
    assert_eq "deleted declared Android display module fails" 2 "$got"
    printf 'include(":app")\n' >"$repo/settings.gradle.kts"
    python3 "$SCRIPT" --repo android --repo-path "$repo" --config "$CONFIG" >/dev/null
    assert_eq "legacy Android app remains supported" 0 "$?"
    rm -rf "$root"
}

# test_repo_path_resolves_repo_relative_roots — per-repo CI scans real files
test_repo_path_resolves_repo_relative_roots() {
    root=$(mktemp -d)
    repo="$root/ios"
    dir="$repo/Vauchi/CoreUI"
    mkdir -p "$dir"
    cat >"$dir/BadView.swift" <<'SW'
class BadView {
    func route(screenId: String) {
        if screenId == "multi_stage_exchange" { startTimer() }
    }
}
SW
    out=$(python3 "$SCRIPT" --repo ios --repo-path "$repo" --config "$CONFIG")
    assert_eq "repo path: scans repo-relative source root" "1" \
        "$(extract_counter "$out" domain_screen_id_branch)"
    rm -rf "$root"
}

# test_windows_display_scans_its_library — the display library left
# windows-app for its own repository (private#1234); the boundary check
# follows it there, accessibility copy included
test_windows_display_scans_its_library() {
    root=$(mktemp -d)
    repo="$root/windows-display"
    dir="$repo/src/Vauchi.Display"
    mkdir -p "$dir"
    cat >"$dir/BadView.cs" <<'CS'
class BadView {
    void Route(string screenId) {
        if (screenId == "multi_stage_exchange") { StartTimer(); }
        AutomationProperties.SetName(button, "Scan");
    }
}
CS
    out=$(python3 "$SCRIPT" --repo windows-display --repo-path "$repo" --config "$CONFIG")
    assert_eq "windows-display: screen-id branch counted" "1" \
        "$(extract_counter "$out" domain_screen_id_branch)"
    assert_eq "windows-display: accessibility copy counted" "1" \
        "$(extract_counter "$out" shell_accessibility_copy)"
    set +e
    python3 "$SCRIPT" --repo windows-display --repo-path "$repo" --config "$CONFIG" \
        --check "$BASELINE" >/dev/null 2>&1
    rc=$?
    set -e
    assert_eq "windows-display: above its zero baseline fails" "1" "$rc"
    rm -rf "$root"
}

# test_repo_path_missing_source_fails — CI must not pass after scanning no files
test_repo_path_missing_source_fails() {
    root=$(mktemp -d)
    set +e
    python3 "$SCRIPT" --repo ios --repo-path "$root" --config "$CONFIG" >/dev/null 2>&1
    rc=$?
    set -e
    assert_eq "repo path: missing configured source exits 2" "2" "$rc"
    rm -rf "$root"
}

# test_counts_violations — planted action-id minting and screen-id branch
test_counts_violations() {
    root=$(mktemp -d)
    dir="$root/ios/Vauchi/CoreUI"
    mkdir -p "$dir"
    cat >"$dir/BadView.swift" <<'SW'
class BadView {
    func makeEditAction(for component: Component) -> String {
        return "\(component.id):edit"
    }
    func route(screenId: String) {
        if screenId == "multi_stage_exchange" { startTimer() }
    }
}
SW
    out=$(python3 "$SCRIPT" --repo ios --workspace-root "$root" --config "$CONFIG")
    assert_eq "violations: action_id_minting == 1" "1" "$(extract_counter "$out" action_id_minting)"
    assert_eq "violations: domain_screen_id_branch == 1" "1" "$(extract_counter "$out" domain_screen_id_branch)"
    rm -rf "$root"
}

# test_todo_suppresses — TODO(HUMBLE) within lookback window suppresses
test_todo_suppresses() {
    root=$(mktemp -d)
    dir="$root/ios/Vauchi/CoreUI"
    mkdir -p "$dir"
    cat >"$dir/AnnotatedView.swift" <<'SW'
class AnnotatedView {
    // TODO(HUMBLE): action-id minting grandfathered until core supplies edit_action_id
    func makeEditAction(for component: Component) -> String {
        return "\(component.id):edit"
    }
}
SW
    out=$(python3 "$SCRIPT" --repo ios --workspace-root "$root" --config "$CONFIG")
    assert_eq "todo: action_id_minting == 0" "0" "$(extract_counter "$out" action_id_minting)"
    rm -rf "$root"
}

# test_exception_suppresses — HUMBLE-EXCEPTION marker suppresses
test_exception_suppresses() {
    root=$(mktemp -d)
    dir="$root/ios/Vauchi/CoreUI"
    mkdir -p "$dir"
    cat >"$dir/ExceptedView.swift" <<'SW'
class ExceptedView {
    // HUMBLE-EXCEPTION: ADR-043 Am6 — temporary bridge until core emits icon_token
    func iconForFieldType(_ type: String) -> String { "phone" }
}
SW
    out=$(python3 "$SCRIPT" --repo ios --workspace-root "$root" --config "$CONFIG")
    assert_eq "exception: field_visibility_interpretation == 0" "0" "$(extract_counter "$out" field_visibility_interpretation)"
    rm -rf "$root"
}

# test_excluded_paths — Generated/ and test trees do not count
test_excluded_paths() {
    root=$(mktemp -d)
    real="$root/ios/Vauchi/CoreUI"
    gen="$root/ios/Vauchi/Generated"
    tests="$root/ios/VauchiTests"
    mkdir -p "$real" "$gen" "$tests"
    cat >"$real/RealView.swift" <<'SW'
class RealView {
    func route(screenId: String) {
        if screenId == "multi_stage_exchange" { startTimer() }
    }
}
SW
    cat >"$gen/GenView.swift" <<'SW'
class GenView {
    func route(screenId: String) {
        if screenId == "multi_stage_exchange" { startTimer() }
    }
}
SW
    cat >"$tests/NavTests.swift" <<'SW'
class NavTests {
    func route(screenId: String) {
        if screenId == "multi_stage_exchange" { startTimer() }
    }
}
SW
    out=$(python3 "$SCRIPT" --repo ios --workspace-root "$root" --config "$CONFIG")
    assert_eq "excluded: only real code counts == 1" "1" "$(extract_counter "$out" domain_screen_id_branch)"
    rm -rf "$root"
}

# test_check_above_baseline_fails — regression exits 1
test_check_above_baseline_fails() {
    root=$(mktemp -d)
    dir="$root/ios/Vauchi/CoreUI"
    mkdir -p "$dir"
    cat >"$dir/BadView.swift" <<'SW'
class BadView {
    func route(screenId: String) {
        if screenId == "multi_stage_exchange" { startTimer() }
    }
}
SW
    base="$root/baseline.json"
    cat >"$base" <<'JSON'
{
  "schema_version": 1,
  "repos": {
    "ios": {
      "domain_screen_id_branch": 0,
      "action_id_minting": 0
    }
  }
}
JSON
    set +e
    python3 "$SCRIPT" --repo ios --workspace-root "$root" --config "$CONFIG" --check "$base" >/dev/null 2>&1
    rc=$?
    set -e
    assert_eq "check: exit 1 when count exceeds baseline" "1" "$rc"
    rm -rf "$root"
}

# test_check_at_baseline_passes — no regression exits 0
test_check_at_baseline_passes() {
    root=$(mktemp -d)
    dir="$root/ios/Vauchi/CoreUI"
    mkdir -p "$dir"
    cat >"$dir/BadView.swift" <<'SW'
class BadView {
    func route(screenId: String) {
        if screenId == "multi_stage_exchange" { startTimer() }
    }
}
SW
    base="$root/baseline.json"
    cat >"$base" <<'JSON'
{
  "repos": {
    "ios": {
      "domain_screen_id_branch": 1,
      "action_id_minting": 0
    }
  }
}
JSON
    set +e
    python3 "$SCRIPT" --repo ios --workspace-root "$root" --config "$CONFIG" --check "$base" >/dev/null 2>&1
    rc=$?
    set -e
    assert_eq "check: exit 0 at baseline" "0" "$rc"
    rm -rf "$root"
}

# test_json_validity — snapshot output is valid JSON
test_json_validity() {
    root=$(mktemp -d)
    out=$(python3 "$SCRIPT" --repo ios --workspace-root "$root" --config "$CONFIG")
    if printf '%s' "$out" | python3 -m json.tool >/dev/null 2>&1; then
        printf '  PASS json: parses as JSON\n'; pass=$((pass + 1))
    else
        printf '  FAIL json: invalid JSON\n    output: %s\n' "$out" >&2
        fail=$((fail + 1))
    fi
    rm -rf "$root"
}

# test_app_screen_enum_branch_rust — match/comparison/matches!/goto on core AppScreen counts
test_app_screen_enum_branch_rust() {
    root=$(mktemp -d)
    dir="$root/tui/src/ui"
    mkdir -p "$dir"
    cat >"$dir/render.rs" <<'RS'
fn tab(app: &App) -> usize {
    match app.current_app_screen() {
        AppScreen::Lock => 0,
        AppScreen::Onboarding => 1,
        AppScreen::Contacts | AppScreen::ContactDetail { .. } => 2,
    }
}
fn is_form(app: &App) -> bool {
    matches!(app.current_app_screen(), AppScreen::FormDialog { .. })
}
fn go(app: &mut App) {
    app.goto(AppScreen::Settings);
}
fn eq(app: &App) -> bool {
    app.current_app_screen() == AppScreen::Lock
}
RS
    # Opaque rendering must not add to the count (true negative).
    cat >"$dir/opaque.rs" <<'RS'
fn render(model: &ScreenModel) {
    for component in &model.components {
        draw(component);
    }
    dispatch(UserAction::NavigateToTab { action_id });
}
RS
    out=$(python3 "$SCRIPT" --repo tui --workspace-root "$root" --config "$CONFIG")
    assert_eq "app_screen rust: branch sites counted, opaque render ignored" "6" "$(extract_counter "$out" app_screen_enum_branch)"
    rm -rf "$root"
}

# test_app_screen_enum_branch_kotlin — local Screen enum decl + when-arms + comparison
test_app_screen_enum_branch_kotlin() {
    root=$(mktemp -d)
    dir="$root/android/app/src/main/kotlin/app/vauchi"
    mkdir -p "$dir"
    cat >"$dir/Main.kt" <<'KT'
enum class Screen {
    Home, NfcExchange, Recovery,
}
fun render(screen: Screen) {
    when (screen) {
        Screen.Home -> renderHome()
        Screen.NfcExchange -> renderNfc()
    }
    if (screen == Screen.Recovery) { back() }
    var current = Screen.Home
}
KT
    out=$(python3 "$SCRIPT" --repo android --workspace-root "$root" --config "$CONFIG")
    assert_eq "app_screen kotlin: enum decl + arms + comparison + assignment" "5" "$(extract_counter "$out" app_screen_enum_branch)"
    rm -rf "$root"
}

# test_app_screen_enum_branch_true_negatives — opaque native code must not fire
test_app_screen_enum_branch_true_negatives() {
    root=$(mktemp -d)
    dir="$root/android/app/src/main/kotlin/app/vauchi"
    mkdir -p "$dir"
    cat >"$dir/Opaque.kt" <<'KT'
fun render(model: ScreenModel, screen: NativeScreen) {
    renderComponents(model.components)
    when (screen.nativeWrapperHint) {
        NativeWrapperHint.MultiStageExchange -> showExchange()
        else -> showHome()
    }
    dispatch(NavigateToTab(actionId))
}
KT
    out=$(python3 "$SCRIPT" --repo android --workspace-root "$root" --config "$CONFIG")
    assert_eq "app_screen kotlin: native wrapper branch ignored" "0" \
        "$(extract_counter "$out" app_screen_enum_branch)"
    assert_eq "boundary: ScreenModel counted" "1" \
        "$(extract_counter "$out" retired_screen_model)"
    assert_eq "boundary: UserAction replacement counted" "0" \
        "$(extract_counter "$out" retired_user_action)"
    rm -rf "$root"
}

# test_visibility_labels_are_unsuppressible_boundary_debt — labels decide
# domain visibility and cannot be grandfathered in a display-only shell.
test_visibility_labels_are_unsuppressible_boundary_debt() {
    root=$(mktemp -d)
    dir="$root/ios/Vauchi/CoreUI"
    mkdir -p "$dir"
    cat >"$dir/Visibility.swift" <<'SW'
struct Visibility {
    // TODO(HUMBLE): legacy label is still domain policy.
    let visibility_label: String
    let visibilityLabel: String
}
SW
    out=$(python3 "$SCRIPT" --repo ios --workspace-root "$root" --config "$CONFIG")
    assert_eq "boundary: visibility labels are unsuppressible" "2" \
        "$(extract_counter "$out" retired_visibility_labels)"
    assert_eq "boundary: visibility labels do not rewrite existing counters" "0" \
        "$(extract_counter "$out" retired_domain_components)"
    rm -rf "$root"
}

# test_app_screen_enum_branch_exception — TODO(HUMBLE) suppresses a branch site
test_app_screen_enum_branch_exception() {
    root=$(mktemp -d)
    dir="$root/tui/src/ui"
    mkdir -p "$dir"
    cat >"$dir/render.rs" <<'RS'
fn go(app: &mut App) {
    // TODO(HUMBLE): D — grandfathered navigation until core owns routing
    app.goto(AppScreen::Settings);
}
RS
    out=$(python3 "$SCRIPT" --repo tui --workspace-root "$root" --config "$CONFIG")
    assert_eq "app_screen rust: TODO(HUMBLE) suppresses" "0" "$(extract_counter "$out" app_screen_enum_branch)"
    rm -rf "$root"
}

# test_bad_repo — unknown repo exits 2
test_bad_repo() {
    root=$(mktemp -d)
    set +e
    python3 "$SCRIPT" --repo unknown --workspace-root "$root" --config "$CONFIG" >/dev/null 2>&1
    rc=$?
    set -e
    assert_eq "bad repo: exit 2" "2" "$rc"
    rm -rf "$root"
}

# test_baseline_transition_cannot_increase_or_remove — ratchets are immutable
test_baseline_transition_cannot_increase_or_remove() {
    root=$(mktemp -d)
    previous="$root/previous.json"
    current="$root/current.json"
    cat >"$previous" <<'JSON'
{
  "repos": {
    "ios": {
      "retired_screen_model": 3,
      "retired_user_action": 2
    }
  }
}
JSON
    cat >"$current" <<'JSON'
{
  "repos": {
    "ios": {
      "retired_screen_model": 4
    }
  }
}
JSON
    set +e
    python3 "$SCRIPT" --validate-baseline "$current" --against "$previous" \
        --config "$CONFIG" >/dev/null 2>&1
    rc=$?
    set -e
    assert_eq "baseline transition: increase/removal exits 1" "1" "$rc"

    cat >"$current" <<'JSON'
{
  "repos": {
    "ios": {
      "retired_screen_model": 2,
      "retired_user_action": 0,
      "new_rule": 7
    }
  }
}
JSON
    set +e
    python3 "$SCRIPT" --validate-baseline "$current" --against "$previous" \
        --config "$CONFIG" >/dev/null 2>&1
    rc=$?
    set -e
    assert_eq "baseline transition: decreases and new rules pass" "0" "$rc"
    rm -rf "$root"
}

# test_baseline_transition_follows_a_rename — a repository whose key moved
# to the name an alias gives it keeps its counters (private#1029); the same
# counts under the new key are no removal, a higher one is still refused,
# and a key that vanishes without an alias is still a removal.
test_baseline_transition_follows_a_rename() {
    root=$(mktemp -d)
    previous="$root/previous.json"
    current="$root/current.json"
    config="$root/rules.json"
    python3 - "$CONFIG" "$config" <<'PY'
import json, sys
c = json.load(open(sys.argv[1]))
c["aliases"] = {"old-shell": "new-shell"}
json.dump(c, open(sys.argv[2], "w"))
PY
    cat >"$previous" <<'JSON'
{"schema_version":2,"repos":{"old-shell":{"retired_screen_model":3},"ios":{"retired_screen_model":1}}}
JSON
    for spec in "3:1:0:renamed key with the same count passes" \
                "4:1:1:renamed key with a higher count exits 1" \
                "3:0:1:a key gone without an alias is still a removal"; do
        count=${spec%%:*}; rest=${spec#*:}; keep_ios=${rest%%:*}; rest=${rest#*:}
        expect=${rest%%:*}; label=${rest#*:}
        if [ "$keep_ios" = 1 ]; then
            ios=',"ios":{"retired_screen_model":1}'
        else
            ios=''
        fi
        printf '{"schema_version":2,"repos":{"new-shell":{"retired_screen_model":%s}%s}}\n' \
            "$count" "$ios" >"$current"
        set +e
        python3 "$SCRIPT" --validate-baseline "$current" --against "$previous" \
            --config "$config" >/dev/null 2>&1
        rc=$?
        set -e
        assert_eq "baseline transition: $label" "$expect" "$rc"
    done
    rm -rf "$root"
}

# test_schema_two_bootstrap_accepts_corrected_measurement — one-time scanner fix
test_schema_two_bootstrap_accepts_corrected_measurement() {
    root=$(mktemp -d)
    previous="$root/previous.json"
    current="$root/current.json"
    cat >"$previous" <<'JSON'
{"schema_version":1,"repos":{"android":{"notification_category_mapping":2}}}
JSON
    cat >"$current" <<'JSON'
{"schema_version":2,"repos":{"android":{"notification_category_mapping":8}}}
JSON
    set +e
    python3 "$SCRIPT" --validate-baseline "$current" --against "$previous" \
        --config "$CONFIG" >/dev/null 2>&1
    rc=$?
    set -e
    assert_eq "baseline transition: schema-two bootstrap passes once" "0" "$rc"
    rm -rf "$root"
}

# test_release_zero_requires_live_and_baseline_zero — release cannot stagnate
test_release_zero_requires_live_and_baseline_zero() {
    root=$(mktemp -d)
    dir="$root/sample/src"
    mkdir -p "$dir"
    config="$root/rules.json"
    baseline="$root/baseline.json"
    cat >"$config" <<'JSON'
{
  "repos": {
    "sample": {
      "source_roots": ["sample/src"],
      "extensions": [".txt"],
      "exclude_dirs": [],
      "rules": {
        "domain_branch": {
          "message": "sample domain branch",
          "patterns": ["DOMAIN"]
        }
      }
    }
  }
}
JSON
    printf 'DOMAIN\n' >"$dir/source.txt"
    cat >"$baseline" <<'JSON'
{"repos":{"sample":{"domain_branch":0}}}
JSON
    set +e
    python3 "$SCRIPT" --release-zero --workspace-root "$root" \
        --config "$config" --check "$baseline" >/dev/null 2>&1
    live_rc=$?
    set -e
    assert_eq "release zero: live finding exits 1" "1" "$live_rc"

    printf 'generic\n' >"$dir/source.txt"
    cat >"$baseline" <<'JSON'
{"repos":{"sample":{"domain_branch":1}}}
JSON
    set +e
    python3 "$SCRIPT" --release-zero --workspace-root "$root" \
        --config "$config" --check "$baseline" >/dev/null 2>&1
    baseline_rc=$?
    set -e
    assert_eq "release zero: nonzero baseline exits 1" "1" "$baseline_rc"

    cat >"$baseline" <<'JSON'
{"repos":{"sample":{"domain_branch":0}}}
JSON
    set +e
    python3 "$SCRIPT" --release-zero --workspace-root "$root" \
        --config "$config" --check "$baseline" >/dev/null 2>&1
    zero_rc=$?
    set -e
    assert_eq "release zero: clean source and baseline pass" "0" "$zero_rc"
    rm -rf "$root"
}

# test_enforcement_wiring — local and remote gates invoke the same checker
test_enforcement_wiring() {
    pre_push_calls=$(grep -c 'humble_check.py.*--repo' "$PRE_PUSH" || true)
    ci_transition_calls=$(grep -c -- '--validate-baseline' "$SCRIPTS_CI" || true)
    assert_eq "wiring: pre-push invokes repository ratchet" "1" "$pre_push_calls"
    assert_eq "wiring: scripts CI validates baseline transition" "1" \
        "$ci_transition_calls"
}

# test_verified_fetch_hashes_match — consumers execute exactly these gates
test_verified_fetch_hashes_match() {
    expected_script=$(grep -A3 'humble_check.py"' "$CROSS_CUTTING_TEMPLATE" \
        | grep 'FETCH_SCRIPT_SHA256=' | head -1 | cut -d'"' -f2)
    expected_config=$(grep -A3 'humble_check_rules.json"' "$CROSS_CUTTING_TEMPLATE" \
        | grep 'FETCH_SCRIPT_SHA256=' | head -1 | cut -d'"' -f2)
    expected_baseline=$(grep -A3 'humble_check.baseline.json"' "$CROSS_CUTTING_TEMPLATE" \
        | grep 'FETCH_SCRIPT_SHA256=' | head -1 | cut -d'"' -f2)
    actual_script=$(shasum -a 256 "$SCRIPT" | awk '{print $1}')
    actual_config=$(shasum -a 256 "$CONFIG" | awk '{print $1}')
    actual_baseline=$(shasum -a 256 "$BASELINE" | awk '{print $1}')
    assert_eq "verified fetch: checker hash matches" "$actual_script" \
        "$expected_script"
    assert_eq "verified fetch: config hash matches" "$actual_config" \
        "$expected_config"
    assert_eq "verified fetch: baseline hash matches" "$actual_baseline" \
        "$expected_baseline"
}

# test_require_zero — release mode rejects any live violation, independently
# of the non-increasing baseline used by merge-request ratchets.
test_require_zero() {
    root=$(mktemp -d)
    dir="$root/ios/Vauchi/CoreUI"
    mkdir -p "$dir"
    cat >"$dir/BadView.swift" <<'SW'
class BadView {
    func route(screenId: String) {
        if screenId == "multi_stage_exchange" { startTimer() }
    }
}
SW
    set +e
    python3 "$SCRIPT" --repo ios --workspace-root "$root" --config "$CONFIG" --require-zero >/dev/null 2>&1
    rc=$?
    set -e
    assert_eq "require-zero: rejects live violation" "1" "$rc"
    rm -rf "$root"
}

# test_require_zero_ignores_exception_markers — a grandfathered site is still
# boundary debt, and a release may not ship any
test_require_zero_ignores_exception_markers() {
    root=$(mktemp -d)
    dir="$root/ios/Vauchi/CoreUI"
    mkdir -p "$dir"
    # Opaque types only: a `Component` parameter would trip the unsuppressible
    # boundary rules and pass this test without exercising the marker.
    cat >"$dir/AnnotatedView.swift" <<'SW'
class AnnotatedView {
    // TODO(HUMBLE): action-id minting grandfathered until core supplies edit_action_id
    func mintEdit(for node: Node) -> String {
        return "\(node.id):edit"
    }
}
SW
    set +e
    python3 "$SCRIPT" --repo ios --workspace-root "$root" --config "$CONFIG" --require-zero >/dev/null 2>&1
    rc=$?
    set -e
    assert_eq "require-zero: exception marker does not excuse release" "1" "$rc"
    rm -rf "$root"
}

# test_require_zero_rejects_nonzero_stored_baseline — clean source with a
# nonzero stored counter means the baseline was never tightened; release
# must not stagnate on slack
test_require_zero_rejects_nonzero_stored_baseline() {
    root=$(mktemp -d)
    mkdir -p "$root/ios/Vauchi/CoreUI"
    baseline="$root/baseline.json"
    zero="$root/zero.json"
    # The real baseline may carry recorded ios debt, so the zero case gets
    # its own all-zero copy.
    python3 - "$BASELINE" "$baseline" "$zero" <<'PY'
import json, sys
baseline = json.load(open(sys.argv[1], encoding="utf-8"))
baseline["repos"]["ios"] = {rule: 0 for rule in baseline["repos"]["ios"]}
json.dump(baseline, open(sys.argv[3], "w", encoding="utf-8"))
baseline["repos"]["ios"]["action_id_minting"] = 1
json.dump(baseline, open(sys.argv[2], "w", encoding="utf-8"))
PY
    set +e
    python3 "$SCRIPT" --repo ios --workspace-root "$root" --config "$CONFIG" \
        --check "$baseline" --require-zero >/dev/null 2>&1
    rc=$?
    python3 "$SCRIPT" --repo ios --workspace-root "$root" --config "$CONFIG" \
        --check "$zero" --require-zero >/dev/null 2>&1
    zero_rc=$?
    set -e
    assert_eq "require-zero: nonzero stored baseline exits 1" "1" "$rc"
    assert_eq "require-zero: zero baseline and clean source pass" "0" "$zero_rc"
    rm -rf "$root"
}

# test_release_ratchet_zero_template — the release gate reuses the verified
# fetch and baseline instead of downloading an unpinned checker
test_release_ratchet_zero_template() {
    block=$(awk '/^\.release-ratchet-zero:/{on=1; print; next} on && /^[^ #]/{on=0} on' \
        "$CROSS_CUTTING_TEMPLATE")
    case "$block" in
        *"extends: .cross-cutting-lint"*) extends="yes" ;;
        *) extends="no" ;;
    esac
    case "$block" in
        *'CHECK_ARGS: "--require-zero"'*) args="yes" ;;
        *) args="no" ;;
    esac
    case "$block" in
        *'CI_COMMIT_TAG =~ /^v\d+\.\d+\.\d+$/'*) tag_only="yes" ;;
        *) tag_only="no" ;;
    esac
    unverified=$(grep -c 'humble_check.py/raw' "$SCRIPT_DIR/../../ci-templates/release.yml" || true)
    assert_eq "release gate: extends the verified runner" "yes" "$extends"
    assert_eq "release gate: requires zero" "yes" "$args"
    assert_eq "release gate: runs on release tags" "yes" "$tag_only"
    assert_eq "release gate: no unverified checker download" "0" "$unverified"
}

# test_tighten_lowers_stored_counts — a baseline must be able to follow
# counts down, or slack accumulates until the ratchet is inert
test_tighten_lowers_stored_counts() {
    root=$(mktemp -d)
    dir="$root/ios/Vauchi/CoreUI"
    mkdir -p "$dir"
    cat >"$dir/BadView.swift" <<'SW'
class BadView {
    func route(screenId: String) {
        if screenId == "multi_stage_exchange" { startTimer() }
    }
}
SW
    baseline="$root/baseline.json"
    cat >"$baseline" <<'JSON'
{
  "schema_version": 2,
  "repos": {
    "ios": {
      "domain_screen_id_branch": 9,
      "action_id_minting": 4
    }
  }
}
JSON
    python3 "$SCRIPT" --tighten "$baseline" --repo ios --workspace-root "$root" \
        --config "$CONFIG" >/dev/null
    assert_eq "tighten: lowers a counter to its measured value" "1" \
        "$(python3 -c "import json;print(json.load(open('$baseline'))['repos']['ios']['domain_screen_id_branch'])")"
    assert_eq "tighten: lowers an unviolated counter to zero" "0" \
        "$(python3 -c "import json;print(json.load(open('$baseline'))['repos']['ios']['action_id_minting'])")"
    rm -rf "$root"
}

# test_tighten_never_raises_stored_counts — absorbing a regression into the
# baseline is the one thing a ratchet may never do
test_tighten_never_raises_stored_counts() {
    root=$(mktemp -d)
    dir="$root/ios/Vauchi/CoreUI"
    mkdir -p "$dir"
    cat >"$dir/BadView.swift" <<'SW'
class BadView {
    func route(screenId: String) {
        if screenId == "multi_stage_exchange" { startTimer() }
    }
}
SW
    baseline="$root/baseline.json"
    printf '%s\n' '{"schema_version": 2, "repos": {"ios": {"domain_screen_id_branch": 0}}}' >"$baseline"
    python3 "$SCRIPT" --tighten "$baseline" --repo ios --workspace-root "$root" \
        --config "$CONFIG" >/dev/null
    assert_eq "tighten: leaves a counter that is over baseline untouched" "0" \
        "$(python3 -c "import json;print(json.load(open('$baseline'))['repos']['ios']['domain_screen_id_branch'])")"
    rm -rf "$root"
}

# test_tighten_refuses_incomplete_checkout — an unscanned repo measures zero,
# which would silently zero its baseline and forgive every real violation
test_tighten_refuses_incomplete_checkout() {
    root=$(mktemp -d)
    baseline="$root/baseline.json"
    printf '%s\n' '{"schema_version": 2, "repos": {"ios": {"domain_screen_id_branch": 9}}}' >"$baseline"
    set +e
    python3 "$SCRIPT" --tighten "$baseline" --repo ios --workspace-root "$root" \
        --config "$CONFIG" >/dev/null 2>&1
    rc=$?
    set -e
    assert_eq "tighten: refuses an incomplete checkout" "2" "$rc"
    assert_eq "tighten: leaves the baseline unwritten" "9" \
        "$(python3 -c "import json;print(json.load(open('$baseline'))['repos']['ios']['domain_screen_id_branch'])")"
    rm -rf "$root"
}

# test_frontend_image_encoding — ADR-042: a shell passes raw image bytes
# and Core converts avatars; encoding to WebP, JPEG or HEIF or resizing a
# bitmap before handing it on is conversion. PNG export for screenshot
# tools and scaling a pixmap for display are not.
test_frontend_image_encoding() {
    root=$(mktemp -d)
    mkdir -p "$root/android/app/src/main/kotlin" "$root/ios/Vauchi" \
        "$root/linux-qt/src" "$root/windows-app/Vauchi" "$root/linux-gtk/src"
    cat >"$root/android/app/src/main/kotlin/Avatar.kt" <<'KT'
fun shrink(b: Bitmap) = Bitmap.createScaledBitmap(b, 64, 64, true)
fun pack(b: Bitmap, out: OutputStream) = b.compress(Bitmap.CompressFormat.WEBP_LOSSY, 80, out)
KT
    cat >"$root/ios/Vauchi/Avatar.swift" <<'SW'
let bytes = image.jpegData(compressionQuality: 0.8)
let raw = try Data(contentsOf: pickedURL)
SW
    cat >"$root/linux-qt/src/avatar.cpp" <<'CPP'
image.save(&buffer, "WEBP");
grab().save(path);
label->setPixmap(pixmap.scaled(32, 32, Qt::KeepAspectRatio));
CPP
    cat >"$root/windows-app/Vauchi/Avatar.cs" <<'CS'
var encoder = await BitmapEncoder.CreateAsync(BitmapEncoder.JpegEncoderId, stream);
var png = await BitmapEncoder.CreateAsync(BitmapEncoder.PngEncoderId, stream);
CS
    mkdir -p "$root/web-demo/src"
    cat >"$root/web-demo/src/avatar.ts" <<'TS'
const shrunk = canvas.toDataURL("image/webp", 0.8);
const shown = `data:image/webp;base64,${btoa(binary)}`;
TS
    cat >"$root/linux-gtk/src/avatar.rs" <<'RS'
let webp = webp::Encoder::from_image(&img).unwrap().encode(80.0);
let png = texture.save_to_png_bytes();
RS
    for spec in android:2 ios:1 linux-qt:1 windows-app:1 linux-gtk:1 web-demo:1; do
        repo=${spec%:*}; want=${spec#*:}
        out=$(python3 "$SCRIPT" --repo "$repo" --workspace-root "$root" --config "$CONFIG")
        assert_eq "image encoding: $repo counts $want" "$want" \
            "$(extract_counter "$out" frontend_image_encoding)"
    done
    rm -rf "$root"
}

# test_shell_accessibility_copy — adr-constraints: accessibility copy is
# Core-prepared; a shell maps the label Core sends and writes none itself.
test_shell_accessibility_copy() {
    root=$(mktemp -d)
    mkdir -p "$root/android/app/src/main/kotlin" "$root/ios/Vauchi" \
        "$root/linux-qt/src" "$root/windows-app/Vauchi" "$root/linux-gtk/src"
    cat >"$root/android/app/src/main/kotlin/Row.kt" <<'KT'
Icon(Icons.Default.Delete, contentDescription = "Delete contact")
Icon(icon, contentDescription = stringResource(R.string.delete))
Icon(icon, contentDescription = node.accessibilityLabel)
KT
    cat >"$root/ios/Vauchi/Row.swift" <<'SW'
.accessibilityLabel("Row actions")
.accessibilityHint(NSLocalizedString("opens", comment: ""))
.accessibilityLabel(node.accessibility.label)
SW
    cat >"$root/linux-qt/src/row.cpp" <<'CPP'
button->setAccessibleName(QStringLiteral("Delete"));
button->setAccessibleDescription(tr("Removes the contact"));
button->setAccessibleName(node.accessibilityLabel);
CPP
    cat >"$root/windows-app/Vauchi/Row.xaml" <<'XAML'
<Button AutomationProperties.Name="Delete" />
<Button AutomationProperties.Name="{x:Bind Node.AccessibilityLabel}" />
XAML
    cat >"$root/linux-gtk/src/row.rs" <<'RS'
button.update_property(&[gtk::accessible::Property::Label("Delete")]);
button.update_property(&[gtk::accessible::Property::Label(&node.accessibility_label)]);
RS
    for spec in android:2 ios:2 linux-qt:2 windows-app:1 linux-gtk:1; do
        repo=${spec%:*}; want=${spec#*:}
        out=$(python3 "$SCRIPT" --repo "$repo" --workspace-root "$root" --config "$CONFIG")
        assert_eq "a11y copy: $repo counts $want" "$want" \
            "$(extract_counter "$out" shell_accessibility_copy)"
    done
    rm -rf "$root"
}

# test_error_substring_classification_desktop_shells — ADR-045 Amendment 1:
# a shell never picks UI by matching an error's text. linux-gtk, cli and
# linux-qt had no such rule; a test assertion on an error message is not
# classification.
test_error_substring_classification_desktop_shells() {
    root=$(mktemp -d)
    mkdir -p "$root/linux-gtk/src" "$root/cli/src" "$root/linux-qt/src"
    cat >"$root/linux-gtk/src/errors.rs" <<'RS'
if err.to_string().contains("locked") { show_unlock(); }
assert!(err.to_string().contains("locked"), "{err}");
RS
    cat >"$root/cli/src/errors.rs" <<'RS'
} else if e.to_string().starts_with("network") { retry(); }
    err.to_string().contains("VAUCHI_PIN"),
RS
    cat >"$root/linux-qt/src/errors.cpp" <<'CPP'
if (error.contains(QStringLiteral("locked"))) { showUnlock(); }
if (message.startsWith("network")) { retry(); }
QVERIFY(errorText.contains("locked"));
CPP
    for spec in linux-gtk:1 cli:1 linux-qt:2; do
        repo=${spec%:*}; want=${spec#*:}
        out=$(python3 "$SCRIPT" --repo "$repo" --workspace-root "$root" --config "$CONFIG")
        assert_eq "error substring: $repo counts $want" "$want" \
            "$(extract_counter "$out" error_substring_classification)"
    done
    rm -rf "$root"
}

# test_renamed_repo_keeps_its_rules — ADR-078 renamed linux-gtk to
# gtk-display and linux-qt to qt-display (private#1029). The rules and the
# baseline are keyed by the new names; the old name still reaches them, from
# a pin bump or a slot that has not moved its checkout, and a workspace
# that still holds the old directory is read there.
test_renamed_repo_keeps_its_rules() {
    # assert_eq assigns name, want and got globally; the loop keeps its own.
    root=$(mktemp -d)
    old_ws=$(mktemp -d)
    for ws in "$root:gtk-display:qt-display" "$old_ws:linux-gtk:linux-qt"; do
        dir=${ws%%:*}; rest=${ws#*:}; gtk=${rest%%:*}; qt=${rest#*:}
        mkdir -p "$dir/$gtk/src" "$dir/$qt/src"
        cat >"$dir/$gtk/src/errors.rs" <<'RS'
if err.to_string().contains("locked") { show_unlock(); }
RS
        cat >"$dir/$qt/src/errors.cpp" <<'CPP'
if (error.contains(QStringLiteral("locked"))) { showUnlock(); }
if (message.startsWith("network")) { retry(); }
CPP
    done
    for spec in gtk-display:linux-gtk:1 qt-display:linux-qt:2; do
        repo=${spec%%:*}; rest=${spec#*:}; old=${rest%:*}; expect=${rest#*:}
        for given in "$repo" "$old"; do
            out=$(python3 "$SCRIPT" --repo "$given" --repo-path "$root/$repo" --config "$CONFIG")
            assert_eq "renamed repo: --repo $given counts $expect" "$expect" \
                "$(extract_counter "$out" error_substring_classification)"
            assert_eq "renamed repo: --repo $given reports as $repo" "1" \
                "$(printf '%s' "$out" | grep -c "\"repo\": \"$repo\"")"
            set +e
            python3 "$SCRIPT" --repo "$given" --repo-path "$root/$repo" --config "$CONFIG" \
                --check "$BASELINE" >/dev/null 2>&1
            rc=$?
            set -e
            assert_eq "renamed repo: --repo $given is held to $repo's baseline" "1" "$rc"
        done
        out=$(python3 "$SCRIPT" --repo "$repo" --workspace-root "$root" --config "$CONFIG")
        assert_eq "workspace: $repo counts $expect in $repo/" "$expect" \
            "$(extract_counter "$out" error_substring_classification)"
        out=$(python3 "$SCRIPT" --repo "$old" --workspace-root "$old_ws" --config "$CONFIG")
        assert_eq "workspace not moved yet: $old counts $expect in $old/" "$expect" \
            "$(extract_counter "$out" error_substring_classification)"
    done
    rm -rf "$root" "$old_ws"
}

# test_terminal_renames_keep_their_rules — ADR-078 step 3 renamed cli and
# tui to cli-display and tui-display (private#1233). The rules and the
# baseline are keyed by the new names; the old name still reaches them, from
# a pin bump or a slot that has not moved its checkout, and a workspace that
# still holds cli/ is read there.
test_terminal_renames_keep_their_rules() {
    root=$(mktemp -d)
    old_ws=$(mktemp -d)
    for dir in "$root/cli-display" "$old_ws/cli"; do
        mkdir -p "$dir/src"
        printf '} else if e.to_string().starts_with("network") { retry(); }\n' >"$dir/src/errors.rs"
    done
    for given in cli-display cli; do
        out=$(python3 "$SCRIPT" --repo "$given" --repo-path "$root/cli-display" --config "$CONFIG")
        assert_eq "cli-display: --repo $given counts the match" "1" \
            "$(extract_counter "$out" error_substring_classification)"
        assert_eq "cli-display: --repo $given reports as cli-display" "1" \
            "$(printf '%s' "$out" | grep -c '"repo": "cli-display"')"
        set +e
        python3 "$SCRIPT" --repo "$given" --repo-path "$root/cli-display" --config "$CONFIG" \
            --check "$BASELINE" >/dev/null 2>&1
        rc=$?
        set -e
        assert_eq "cli-display: --repo $given is held to the cli-display baseline" "1" "$rc"
    done
    out=$(python3 "$SCRIPT" --repo cli-display --workspace-root "$root" --config "$CONFIG")
    assert_eq "workspace: cli-display counts in cli-display/" "1" \
        "$(extract_counter "$out" error_substring_classification)"
    out=$(python3 "$SCRIPT" --repo cli --workspace-root "$old_ws" --config "$CONFIG")
    assert_eq "workspace not moved yet: cli counts in cli/" "1" \
        "$(extract_counter "$out" error_substring_classification)"
    mkdir -p "$root/tui-display/src"
    for given in tui-display tui; do
        set +e
        out=$(python3 "$SCRIPT" --repo "$given" --repo-path "$root/tui-display" --config "$CONFIG")
        rc=$?
        set -e
        assert_eq "tui-display: --repo $given is accepted" "0" "$rc"
        assert_eq "tui-display: --repo $given reports as tui-display" "1" \
            "$(printf '%s' "$out" | grep -c '"repo": "tui-display"')"
    done
    rm -rf "$root" "$old_ws"
}

# test_windows_app_keeps_its_rules — ADR-078 step 4 renamed the windows
# project to windows-app (private#1234). The rules and the baseline are
# keyed by the new name; the old name still reaches them, from a pin bump or
# a slot that has not moved its checkout, and a workspace that still holds
# windows/ is read there. An unknown name is still refused.
test_windows_app_keeps_its_rules() {
    root=$(mktemp -d)
    old_ws=$(mktemp -d)
    for dir in "$root/windows-app" "$old_ws/windows"; do
        mkdir -p "$dir/Vauchi"
        cat >"$dir/Vauchi/Avatar.cs" <<'CS'
var encoder = await BitmapEncoder.CreateAsync(BitmapEncoder.JpegEncoderId, stream);
var png = await BitmapEncoder.CreateAsync(BitmapEncoder.PngEncoderId, stream);
CS
    done
    for given in windows-app windows; do
        out=$(python3 "$SCRIPT" --repo "$given" --repo-path "$root/windows-app" --config "$CONFIG")
        assert_eq "windows-app: --repo $given counts the encoder" "1" \
            "$(extract_counter "$out" frontend_image_encoding)"
        assert_eq "windows-app: --repo $given reports as windows-app" "1" \
            "$(printf '%s' "$out" | grep -c '"repo": "windows-app"')"
        set +e
        python3 "$SCRIPT" --repo "$given" --repo-path "$root/windows-app" --config "$CONFIG" \
            --check "$BASELINE" >/dev/null 2>&1
        rc=$?
        set -e
        assert_eq "windows-app: --repo $given is held to the windows-app baseline" "1" "$rc"
    done
    out=$(python3 "$SCRIPT" --repo windows-app --workspace-root "$root" --config "$CONFIG")
    assert_eq "workspace: windows-app counts in windows-app/" "1" \
        "$(extract_counter "$out" frontend_image_encoding)"
    out=$(python3 "$SCRIPT" --repo windows --workspace-root "$old_ws" --config "$CONFIG")
    assert_eq "workspace not moved yet: windows counts in windows/" "1" \
        "$(extract_counter "$out" frontend_image_encoding)"
    set +e
    python3 "$SCRIPT" --repo windows-apps --repo-path "$root/windows-app" --config "$CONFIG" \
        >/dev/null 2>&1
    rc=$?
    set -e
    assert_eq "windows-app: a name that is not the alias is refused" "2" "$rc"
    rm -rf "$root" "$old_ws"
}

# test_vocabulary_covers_rule_types — the Core schema test reads the shared
# vocabulary instead of restating it, which only holds while the vocabulary
# covers every type the rules grep for
test_vocabulary_covers_rule_types() {
    root=$(mktemp -d)
    config="$root/rules.json"
    python3 - "$CONFIG" "$config" <<'PY'
import json, sys
config = json.load(open(sys.argv[1], encoding="utf-8"))
config["boundary_rules"]["retired_screen_model"]["patterns"].append(r"\bContactRoster\b")
json.dump(config, open(sys.argv[2], "w", encoding="utf-8"), indent=2)
PY
    set +e
    out=$(python3 "$SCRIPT" --repo ios --workspace-root "$root" --config "$config" 2>&1)
    rc=$?
    set -e
    assert_eq "vocabulary: rule type missing from the list fails" "1" "$rc"
    case "$out" in
        *ContactRoster*) got="named" ;;
        *) got="$out" ;;
    esac
    assert_eq "vocabulary: failure names the absent type" "named" "$got"
    rm -rf "$root"
}

# test_vocabulary_allows_entries_without_a_rule — the two are supersets, not
# equals: the ratchet greps prose and would fire on a comment naming a screen
test_vocabulary_allows_entries_without_a_rule() {
    root=$(mktemp -d)
    config="$root/rules.json"
    python3 - "$CONFIG" "$config" <<'PY'
import json, sys
config = json.load(open(sys.argv[1], encoding="utf-8"))
config["retired_boundary_vocabulary"].append("SomeUnscannedName")
json.dump(config, open(sys.argv[2], "w", encoding="utf-8"), indent=2)
PY
    set +e
    python3 "$SCRIPT" --repo ios --workspace-root "$root" --config "$config" >/dev/null 2>&1
    rc=$?
    set -e
    assert_eq "vocabulary: entry without a rule is allowed" "0" "$rc"
    rm -rf "$root"
}

# run
test_empty_workspace
test_repo_path_resolves_repo_relative_roots
test_repo_path_missing_source_fails
test_windows_display_scans_its_library
test_counts_violations
test_todo_suppresses
test_exception_suppresses
test_excluded_paths
test_check_above_baseline_fails
test_check_at_baseline_passes
test_json_validity
test_app_screen_enum_branch_rust
test_app_screen_enum_branch_kotlin
test_app_screen_enum_branch_true_negatives
test_visibility_labels_are_unsuppressible_boundary_debt
test_app_screen_enum_branch_exception
test_bad_repo
test_baseline_transition_cannot_increase_or_remove
test_baseline_transition_follows_a_rename
test_schema_two_bootstrap_accepts_corrected_measurement
test_release_zero_requires_live_and_baseline_zero
test_enforcement_wiring
test_verified_fetch_hashes_match
test_require_zero
test_require_zero_ignores_exception_markers
test_require_zero_rejects_nonzero_stored_baseline
test_release_ratchet_zero_template
test_tighten_lowers_stored_counts
test_tighten_never_raises_stored_counts
test_tighten_refuses_incomplete_checkout
test_vocabulary_covers_rule_types
test_vocabulary_allows_entries_without_a_rule
test_frontend_image_encoding
test_shell_accessibility_copy
test_error_substring_classification_desktop_shells
test_renamed_repo_keeps_its_rules
test_windows_app_keeps_its_rules
test_terminal_renames_keep_their_rules
test_android_display_module_keeps_rules

printf '\n%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
