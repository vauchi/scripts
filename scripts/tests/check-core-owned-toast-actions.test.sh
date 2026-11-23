#!/usr/bin/env bash
# SPDX-FileCopyrightText: 2026 Mattia Egloff <mattia.egloff@pm.me>
# SPDX-License-Identifier: GPL-3.0-or-later

# Non-tautological sentinels for the core-owned ShowToast action gate.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
SCRIPT="$SCRIPT_DIR/../check-core-owned-toast-actions.sh"
pass=0
fail=0

assert_rc() {
    name="$1" want="$2" got="$3"
    if [ "$want" = "$got" ]; then
        printf '  PASS %s\n' "$name"
        pass=$((pass + 1))
    else
        printf '  FAIL %s: wanted rc %s, got %s\n' "$name" "$want" "$got" >&2
        fail=$((fail + 1))
    fi
}

run_rc() {
    set +e
    "$SCRIPT" "$1" >/dev/null 2>&1
    rc=$?
    set -e
    printf '%s' "$rc"
}

test_empty_workspace() {
    root=$(mktemp -d)
    assert_rc 'empty partial workspace is valid' 0 "$(run_rc "$root")"
    rm -rf "$root"
}

test_android_hardcoded_copy() {
    root=$(mktemp -d)
    base="$root/android/app/src/main/kotlin/app/vauchi/ui/coreui"
    mkdir -p "$base"
    printf '%s\n' \
        'val undoLabel: String? obj["undo_label"] JsonPrimitive(value.undoLabel)' >"$base/Models.kt"
    printf '%s\n' \
        'result.undoLabel _toastUndoLabel.value = undoLabel' >"$base/CoreAppViewModel.kt"
    printf '%s\n' \
        'undoLabel = toastUndoLabel UserAction.UndoPressed(actionId = actionId)' >"$base/ScreenRenderer.kt"
    assert_rc 'Android wire-label forwarding passes' 0 "$(run_rc "$root")"
    printf '%s\n' 'undoLabel = "Undo"' >>"$base/ScreenRenderer.kt"
    assert_rc 'Android hardcoded Undo fails' 1 "$(run_rc "$root")"
    rm -rf "$root"
}

test_gtk_hardcoded_copy() {
    root=$(mktemp -d)
    file="$root/gtk-display/src/core_ui/action_dispatcher.rs"
    mkdir -p "$(dirname "$file")"
    printf '%s\n' \
        'Some(undo_label)' \
        'toast.set_button_label(Some(&undo_label));' \
        'UserAction::UndoPressed' >"$file"
    assert_rc 'GTK wire-label forwarding passes' 0 "$(run_rc "$root")"
    printf '%s\n' 'toast.set_button_label(Some("Undo"));' >>"$file"
    assert_rc 'GTK hardcoded Undo fails' 1 "$(run_rc "$root")"
    rm -rf "$root"
}

test_qt_wrong_event() {
    root=$(mktemp -d)
    file="$root/qt-display/src/coreui/screenrenderer.cpp"
    mkdir -p "$(dirname "$file")"
    printf '%s\n' \
        'toast["undo_label"].toString()' \
        'new QPushButton(undoLabel, bar)' \
        'action["UndoPressed"] = inner' >"$file"
    assert_rc 'Qt wire-label forwarding passes' 0 "$(run_rc "$root")"
    printf '%s\n' \
        'toast["undo_label"].toString()' \
        'new QPushButton(undoLabel, bar)' \
        'action["ActionPressed"] = inner' >"$file"
    assert_rc 'Qt wrong toast event fails' 1 "$(run_rc "$root")"
    rm -rf "$root"
}

# tui became tui-display (private#1233); a checkout that has not followed is
# read under its old name, so both directories carry the same contract.
check_tui_contract() {
    dir="$1"
    root=$(mktemp -d)
    base="$root/$dir/src"
    mkdir -p "$base/app" "$base/handlers/input" "$base/ui"
    printf '%s\n' \
        'pub undo_label: Option<String>' 'self.undo_label = undo_label' >"$base/app/mod.rs"
    printf '%s\n' 'undo_label' >"$base/handlers/action_result.rs"
    printf '%s\n' 'format!(" {}  [z] {}", msg, undo_label)' >"$base/ui/mod.rs"
    printf '%s\n' 'UserAction::UndoPressed { action_id }' >"$base/handlers/input/mod.rs"
    assert_rc "$dir wire-label forwarding passes" 0 "$(run_rc "$root")"
    printf '%s\n' 'let hint = " [z] Undo";' >>"$base/ui/mod.rs"
    assert_rc "$dir hardcoded Undo fails" 1 "$(run_rc "$root")"
    rm -rf "$root"
}

test_tui_hardcoded_copy() {
    check_tui_contract tui-display
    check_tui_contract tui
}

test_ios_parallel_undo_path() {
    root=$(mktemp -d)
    base="$root/ios/Vauchi"
    mkdir -p "$base/CoreUI"
    printf '%s\n' \
        'toastUndoLabel' \
        'showToast(message, undoActionId: undoActionId, undoLabel: undoLabel)' \
        >"$base/CoreUI/AppViewModel.swift"
    printf '%s\n' 'undoLabel: coreVM.toastUndoLabel' >"$base/CoreUI/CoreScreenView.swift"
    printf '%s\n' \
        'let undoLabel: String?' \
        'Button(undoLabel)' >"$base/CoreUI/ScreenRendererView.swift"
    printf '%s\n' 'Text(message)' >"$base/ContentView.swift"
    assert_rc 'iOS single core-owned toast path passes' 0 "$(run_rc "$root")"
    printf '%s\n' 'Button("Undo")' >>"$base/ContentView.swift"
    assert_rc 'iOS parallel hardcoded Undo path fails' 1 "$(run_rc "$root")"
    rm -rf "$root"
}

test_empty_workspace
test_android_hardcoded_copy
test_gtk_hardcoded_copy
test_qt_wrong_event
test_ios_parallel_undo_path
test_tui_hardcoded_copy

printf '\n%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
