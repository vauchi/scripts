#!/usr/bin/env bash
# SPDX-FileCopyrightText: 2026 Mattia Egloff <mattia.egloff@pm.me>
# SPDX-License-Identifier: GPL-3.0-or-later

# Non-tautological sentinels for the strict generic-component Humble-UI gate.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
SCRIPT="$SCRIPT_DIR/../check-core-owned-generic-components.sh"
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

make_android_good() {
    root="$1"
    base="$root/android/app/src/main/kotlin/app/vauchi/ui/coreui"
    mkdir -p "$base/components"
    printf '%s\n' \
        'confirmActionId cancelActionId editText saveText cancelText editActionId saveActionId editing statusLabel title' \
        >"$base/Models.kt"
    printf '%s\n' \
        'confirmActionId = component.confirmActionId' \
        'cancelActionId = component.cancelActionId' \
        'editActionId = component.editActionId' \
        'saveActionId = component.saveActionId' \
        'cancelActionId = component.cancelActionId' \
        'editing = component.editing' \
        'statusLabel = component.statusLabel' \
        'title = component.title' \
        'a11y = component.a11y' \
        >"$base/ScreenRenderer.kt"
    printf '%s\n' 'confirmActionId cancelActionId confirmText cancelText' \
        >"$base/components/InlineConfirmComponent.kt"
    printf '%s\n' \
        'editActionId saveActionId cancelActionId editText saveText cancelText editing' \
        >"$base/components/EditableTextComponent.kt"
    printf '%s\n' \
        'editActionId ActionPressed(actionId = editActionId)' \
        >"$base/components/ImageCircleComponent.kt"
    printf '%s\n' 'statusLabel text = statusLabel' \
        >"$base/components/StatusIndicatorComponent.kt"
    printf '%s\n' \
        'a11y?.label ?: label contentDescription = accessibilityLabel' \
        >"$base/components/QrCodeComponent.kt"
    printf '%s\n' 'a11y?.label ?: title' \
        >"$base/components/FieldListComponent.kt"
}

test_android_contract_and_state_sentinel() {
    root=$(mktemp -d)
    make_android_good "$root"
    assert_rc 'android forwarding contract passes' 0 "$(run_rc "$root")"
    printf '%s\n' 'val title = "Contact fields"' \
        >>"$root/android/app/src/main/kotlin/app/vauchi/ui/coreui/components/FieldListComponent.kt"
    assert_rc 'android hardcoded FieldList title fails' 1 "$(run_rc "$root")"
    printf '%s\n' 'a11y?.label ?: title' \
        >"$root/android/app/src/main/kotlin/app/vauchi/ui/coreui/components/FieldListComponent.kt"
    printf '%s\n' 'val editing = remember { mutableStateOf(false) }' \
        >>"$root/android/app/src/main/kotlin/app/vauchi/ui/coreui/components/EditableTextComponent.kt"
    assert_rc 'android local edit state fails' 1 "$(run_rc "$root")"
    rm -rf "$root"
}

test_ios_derived_action_sentinel() {
    root=$(mktemp -d)
    base="$root/ios/Vauchi/CoreUI/Components"
    mkdir -p "$base"
    printf '%s\n' \
        'component.confirmActionId component.cancelActionId component.confirmText component.cancelText' \
        >"$base/InlineConfirmView.swift"
    printf '%s\n' \
        'component.editActionId component.saveActionId component.cancelActionId component.editText component.saveText component.cancelText component.editing' \
        >"$base/EditableTextView.swift"
    printf '%s\n' \
        'component.editActionId actionPressed(actionId: editActionId)' \
        >"$base/ImageCircleView.swift"
    printf '%s\n' '.accessibilityValue(component.statusLabel)' >"$base/StatusIndicatorView.swift"
    printf '%s\n' \
        'component.a11y?.label ?? component.label ?? ""' \
        >"$base/QrCodeView.swift"
    printf '%s\n' '.accessibilityLabel(component.a11y?.label ?? component.title)' \
        >"$base/FieldListView.swift"
    assert_rc 'ios forwarding contract passes' 0 "$(run_rc "$root")"
    printf '%s\n' 'onAction(.actionPressed(actionId: "\(component.id):edit"))' \
        >>"$base/EditableTextView.swift"
    assert_rc 'ios derived edit action fails' 1 "$(run_rc "$root")"
    rm -rf "$root"
}

test_tui_derived_action_sentinel() {
    root=$(mktemp -d)
    keys="$root/tui/src/ui/widgets/key_mapping/component_keys.rs"
    renderer="$root/tui/src/ui/widgets/screen_renderer/mod.rs"
    qr="$root/tui/src/ui/widgets/screen_renderer/render_misc.rs"
    field_list="$root/tui/src/ui/widgets/field_list.rs"
    mkdir -p "$(dirname "$keys")" "$(dirname "$renderer")"
    printf '%s\n' \
        'confirm_action_id cancel_action_id edit_action_id save_action_id cancel_action_id' \
        >"$keys"
    printf '%s\n' 'confirm_text cancel_text edit_text save_text editing status_label,' >"$renderer"
    printf '%s\n' 'edit_action_id' >>"$renderer"
    printf '%s\n' 'edit_action_id: Some(action_id)' >>"$keys"
    printf '%s\n' \
        'let title = label.map(|value| format!(" {value} ")).unwrap_or_default()' \
        >"$qr"
    printf '%s\n' \
        'pub title:' \
        'format!(" {} ", self.title)' \
        '.title(panel_title)' \
        >"$field_list"
    assert_rc 'tui forwarding contract passes' 0 "$(run_rc "$root")"
    printf '%s\n' '" Fields (Show/Hide) "' >>"$field_list"
    assert_rc 'tui mode-derived FieldList title fails' 1 "$(run_rc "$root")"
    printf '%s\n' \
        'pub title:' \
        'format!(" {} ", self.title)' \
        '.title(panel_title)' \
        >"$field_list"
    printf '%s\n' 'let action_id = format!("confirm_{id}");' >>"$keys"
    assert_rc 'tui derived confirm action fails' 1 "$(run_rc "$root")"
    rm -rf "$root"
}

test_web_local_state_sentinel() {
    root=$(mktemp -d)
    inline="$root/web-demo/src/core-ui/components/InlineConfirmComponent.tsx"
    editable="$root/web-demo/src/core-ui/components/EditableTextComponent.tsx"
    image="$root/web-demo/src/core-ui/components/ImageCircleComponent.tsx"
    qr="$root/web-demo/src/core-ui/components/QrCodeComponent.tsx"
    field_list="$root/web-demo/src/core-ui/components/FieldListComponent.tsx"
    types="$root/web-demo/src/types/core.ts"
    mkdir -p "$(dirname "$inline")" "$(dirname "$types")"
    printf '%s\n' \
        'confirm_action_id cancel_action_id edit_text save_text cancel_text edit_action_id save_action_id editing status_label title' \
        >"$types"
    printf '%s\n' \
        'props.confirm_action_id props.cancel_action_id props.confirm_text props.cancel_text' \
        >"$inline"
    printf '%s\n' \
        'props.edit_action_id props.save_action_id props.cancel_action_id props.edit_text props.save_text props.cancel_text props.editing' \
        >"$editable"
    printf '%s\n' 'props.edit_action_id action_id: actionId' >"$image"
    printf '%s\n' 'status_label props.status_label' \
        >"$root/web-demo/src/core-ui/components/StatusIndicatorComponent.tsx"
    printf '%s\n' \
        'props.a11y?.label ?? props.label ?? undefined' \
        'alt={props.a11y?.label ?? props.label ?? ""}' \
        >"$qr"
    printf '%s\n' 'props.a11y?.label ?? props.title' >"$field_list"
    assert_rc 'web forwarding contract passes' 0 "$(run_rc "$root")"
    printf '%s\n' 'ActionPressed: { action_id: "edit_avatar" }' >>"$image"
    assert_rc 'web hardcoded image edit action fails' 1 "$(run_rc "$root")"
    printf '%s\n' 'props.edit_action_id action_id: actionId' >"$image"
    printf '%s\n' 'const [editing] = createSignal(false);' >>"$editable"
    assert_rc 'web local edit state fails' 1 "$(run_rc "$root")"
    printf '%s\n' \
        'props.edit_action_id props.save_action_id props.cancel_action_id props.edit_text props.save_text props.cancel_text props.editing' \
        >"$editable"
    printf '%s\n' 'status_label props.status_label >{props.status}<' \
        >"$root/web-demo/src/core-ui/components/StatusIndicatorComponent.tsx"
    assert_rc 'web derived status label fails' 1 "$(run_rc "$root")"
    printf '%s\n' 'status_label props.status_label' \
        >"$root/web-demo/src/core-ui/components/StatusIndicatorComponent.tsx"
    printf '%s\n' 'alt="QR Code"' >>"$qr"
    assert_rc 'web hardcoded QR accessibility copy fails' 1 "$(run_rc "$root")"
    rm -rf "$root"
}

test_empty_workspace
test_android_contract_and_state_sentinel
test_ios_derived_action_sentinel
test_tui_derived_action_sentinel
test_web_local_state_sentinel

printf '\n%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
