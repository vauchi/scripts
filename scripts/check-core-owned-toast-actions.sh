#!/usr/bin/env bash
# SPDX-FileCopyrightText: 2026 Mattia Egloff <mattia.egloff@pm.me>
# SPDX-License-Identifier: GPL-3.0-or-later

# Strict ADR-021/043/044 guard for ActionResult::ShowToast. Core owns the
# optional action label and opaque id; shells render the label verbatim and
# forward the id as UndoPressed while retaining native toast timing/layout.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT="${1:-$(cd "$SCRIPT_DIR/../.." && pwd)}"

if [ ! -d "$ROOT" ]; then
    printf 'core-owned-toast-actions: workspace %s does not exist\n' "$ROOT" >&2
    exit 2
fi

failures=0
checks=0

fail() {
    printf 'VIOLATION %s\n' "$1" >&2
    failures=$((failures + 1))
}

require_file() {
    file="$1"
    checks=$((checks + 1))
    if [ ! -f "$ROOT/$file" ]; then
        fail "$file: required toast contract file is missing"
        return 1
    fi
}

require_token() {
    file="$1"
    token="$2"
    reason="$3"
    checks=$((checks + 1))
    if ! grep -Fq "$token" "$ROOT/$file"; then
        fail "$file: missing $reason ($token)"
    fi
}

require_tokens() {
    file="$1"
    reason="$2"
    shift 2
    for token in "$@"; do
        require_token "$file" "$token" "$reason"
    done
}

forbid_regex() {
    file="$1"
    regex="$2"
    reason="$3"
    checks=$((checks + 1))
    if grep -En "$regex" "$ROOT/$file" >/dev/null 2>&1; then
        grep -En "$regex" "$ROOT/$file" >&2 || true
        fail "$file: $reason"
    fi
}

check_core() {
    [ -d "$ROOT/core" ] || return 0
    action='core/vauchi-app/src/ui/action.rs'
    routing='core/vauchi-app/src/ui/app_engine/routing.rs'
    reminder='core/vauchi-app/src/ui/app_engine/mod.rs'
    schema='core/vauchi-core/schemas/action-result.schema.json'
    for file in "$action" "$routing" "$reminder" "$schema"; do
        require_file "$file" || return 0
    done
    require_tokens "$action" 'backward-compatible core toast label field' \
        'undo_label: Option<String>' 'serde(default, skip_serializing_if = "Option::is_none")'
    require_token "$routing" 'undo_label: Some(self.t("action.undo"))' \
        'core-localized reversible action copy'
    require_token "$reminder" 'undo_label: Some(self.t("backup.wizard.create"))' \
        'core-localized backup action copy'
    require_token "$schema" '"undo_label"' 'generated ShowToast wire schema field'
}

check_android() {
    [ -d "$ROOT/android" ] || return 0
    model='android/app/src/main/kotlin/app/vauchi/ui/coreui/Models.kt'
    vm='android/app/src/main/kotlin/app/vauchi/ui/coreui/CoreAppViewModel.kt'
    renderer='android/app/src/main/kotlin/app/vauchi/ui/coreui/ScreenRenderer.kt'
    for file in "$model" "$vm" "$renderer"; do require_file "$file" || return 0; done
    require_tokens "$model" 'ShowToast undo label wire parsing' \
        'val undoLabel: String?' 'obj["undo_label"]' 'JsonPrimitive(value.undoLabel)'
    require_tokens "$vm" 'verbatim toast label state forwarding' \
        'result.undoLabel' '_toastUndoLabel.value = undoLabel'
    require_tokens "$renderer" 'verbatim native toast action' \
        'undoLabel = toastUndoLabel' 'UserAction.UndoPressed(actionId = actionId)'
    forbid_regex "$renderer" 'undoLabel[[:space:]]*=[[:space:]]*if.*"Undo"|undoLabel[[:space:]]*=[[:space:]]*"Undo"' \
        'renderer must not invent English Undo copy'
}

check_swift_model() {
    [ -d "$ROOT/vauchi-platform-swift" ] || return 0
    file='vauchi-platform-swift/Sources/CoreUIModels/Models.swift'
    require_file "$file" || return 0
    require_tokens "$file" 'shared Apple ShowToast undo label decoding' \
        'case showToast(message: String, undoActionId: String?, undoLabel: String?)' \
        'undoLabel: data.undoLabel' 'let undoLabel: String?'
}

check_apple() {
    repo="$1"
    vm="$2"
    host="$3"
    [ -d "$ROOT/$repo" ] || return 0
    renderer="$repo/Vauchi/CoreUI/ScreenRendererView.swift"
    for file in "$repo/$vm" "$repo/$host" "$renderer"; do require_file "$file" || return 0; done
    require_tokens "$repo/$vm" 'verbatim toast label state forwarding' \
        'toastUndoLabel' 'showToast(message, undoActionId: undoActionId, undoLabel: undoLabel)'
    require_token "$repo/$host" 'undoLabel:' 'toast host forwards the core label'
    require_tokens "$renderer" 'verbatim native toast action' \
        'let undoLabel: String?' 'Button(undoLabel)'
    forbid_regex "$renderer" 'Button\("Undo"\)|Button\(localizationService[.]t\("action[.]undo"\)\)' \
        'renderer must not invent or localize Undo copy'
    if [ -f "$ROOT/$repo/Vauchi/ContentView.swift" ]; then
        forbid_regex "$repo/Vauchi/ContentView.swift" 'Button\("Undo"\)' \
            'shell must not retain a parallel frontend-owned Undo toast path'
    fi
}

check_gtk() {
    gtk='gtk-display'
    [ -d "$ROOT/$gtk" ] || gtk='linux-gtk'
    [ -d "$ROOT/$gtk" ] || return 0
    file="$gtk/src/core_ui/action_dispatcher.rs"
    require_file "$file" || return 0
    require_tokens "$file" 'verbatim GTK toast action' \
        'Some(undo_label)' 'toast.set_button_label(Some(&undo_label))' 'UserAction::UndoPressed'
    forbid_regex "$file" 'set_button_label\(Some\("Undo"\)\)' \
        'GTK must not invent English Undo copy'
}

check_qt() {
    qt='qt-display'
    [ -d "$ROOT/$qt" ] || qt='linux-qt'
    [ -d "$ROOT/$qt" ] || return 0
    file="$qt/src/coreui/screenrenderer.cpp"
    require_file "$file" || return 0
    require_tokens "$file" 'verbatim Qt toast action' \
        'toast["undo_label"].toString()' 'new QPushButton(undoLabel, bar)' \
        'action["UndoPressed"] = inner'
    forbid_regex "$file" 'new QPushButton\((tr\("Undo"\)|QStringLiteral\("Undo"\)|"Undo")' \
        'Qt must not invent or localize Undo copy'
}

check_windows() {
    # windows was renamed to windows-app (private#1234).
    win='windows-app'
    [ -d "$ROOT/$win" ] || win='windows'
    [ -d "$ROOT/$win" ] || return 0
    file="$win/Vauchi/MainWindow.xaml.cs"
    require_file "$file" || return 0
    require_tokens "$file" 'verbatim WinUI toast action' \
        'TryGetProperty("undo_label"' 'FloatingToastAction.Content = undoLabel' \
        'ActionJson.UndoPressed(actionId)'
    forbid_regex "$file" 'FloatingToastAction[.]Content[[:space:]]*=[[:space:]]*(Localizer[.]T\("action[.]undo"\)|"Undo")' \
        'Windows must not invent or localize Undo copy'
}

check_tui() {
    # tui was renamed to tui-display (private#1233).
    tui='tui-display'
    [ -d "$ROOT/$tui" ] || tui='tui'
    [ -d "$ROOT/$tui" ] || return 0
    app="$tui/src/app/mod.rs"
    handler="$tui/src/handlers/action_result.rs"
    ui="$tui/src/ui/mod.rs"
    input="$tui/src/handlers/input/mod.rs"
    for file in "$app" "$handler" "$ui" "$input"; do require_file "$file" || return 0; done
    require_tokens "$app" 'terminal toast label state' \
        'pub undo_label: Option<String>' 'self.undo_label = undo_label'
    require_token "$handler" 'undo_label' 'ShowToast label forwarding'
    require_token "$ui" 'format!(" {}  [z] {}", msg, undo_label)' \
        'verbatim terminal toast action copy'
    require_token "$input" 'UserAction::UndoPressed { action_id }' \
        'correct terminal toast action event'
    forbid_regex "$ui" '\[z\][[:space:]]+Undo' 'TUI must not invent English Undo copy'
}

check_web() {
    [ -d "$ROOT/web-demo" ] || return 0
    file='web-demo/src/App.tsx'
    require_file "$file" || return 0
    require_tokens "$file" 'verbatim web toast action' \
        'actionLabel: result.ShowToast.undo_label' \
        'const actionId = t().actionId' \
        'UndoPressed: { action_id: actionId }' '{t().actionLabel}'
    forbid_regex "$file" '>Undo<|actionLabel:[[:space:]]*"Undo"' \
        'web demo must not invent English Undo copy'
}

check_core
check_android
check_swift_model
check_apple ios 'Vauchi/CoreUI/AppViewModel.swift' 'Vauchi/CoreUI/CoreScreenView.swift'
check_apple macos 'Vauchi/ViewModels/AppViewModel.swift' 'Vauchi/CoreUI/AppContentView.swift'
check_gtk
check_qt
check_windows
check_tui
check_web

if [ "$failures" -ne 0 ]; then
    printf 'core-owned-toast-actions: FAIL — %d violation(s) across %d checks\n' \
        "$failures" "$checks" >&2
    exit 1
fi

printf 'core-owned-toast-actions: OK — %d strict contract checks passed\n' "$checks"
