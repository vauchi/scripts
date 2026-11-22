#!/usr/bin/env bash
# SPDX-FileCopyrightText: 2026 Mattia Egloff <mattia.egloff@pm.me>
# SPDX-License-Identifier: GPL-3.0-or-later

# Strict ADR-021/043/044 guard for generic components whose workflow
# contract was historically completed by each frontend:
#
#   InlineConfirm: core owns copy plus confirm/cancel action ids.
#   EditableText:  core owns copy, edit/save/cancel action ids, and edit mode.
#   ImageCircle:   core owns whether an edit action exists and its opaque id.
#   StatusIndicator: core owns the localized semantic status label.
#   QrCode: core owns the localized visible/accessibility label; the mode may
#           select native display/scanner hardware only.
#   FieldList: core owns the localized group/panel title; visibility mode may
#              select native control layout only.
#
# Frontends may render those values and forward hardware/user events. They may
# not mint an id from the component id, supply fallback workflow copy, or own
# edit-mode state. The check is deliberately scoped to these six components;
# the wider Humble-UI debt remains tracked by the platform problem records.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT="${1:-$(cd "$SCRIPT_DIR/../.." && pwd)}"

if [ ! -d "$ROOT" ]; then
    printf 'core-owned-generic-components: workspace %s does not exist\n' "$ROOT" >&2
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
        fail "$file: required renderer/model file is missing"
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

forbid_regex() {
    file="$1"
    regex="$2"
    reason="$3"
    checks=$((checks + 1))
    if grep -En "$regex" "$ROOT/$file" >/dev/null 2>&1; then
        printf '  %s\n' "$reason" >&2
        grep -En "$regex" "$ROOT/$file" >&2 || true
        fail "$file: $reason"
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

check_core() {
    [ -d "$ROOT/core" ] || return 0
    component='core/vauchi-app/src/ui/component/mod.rs'
    contact_edit='core/vauchi-app/src/ui/contact_edit.rs'
    success='core/vauchi-app/src/ui/exchange/success.rs'
    schema='core/vauchi-core/schemas/screen-model.schema.json'
    for file in "$component" "$contact_edit" "$success" "$schema"; do require_file "$file" || return 0; done
    require_tokens "$component" 'backward-compatible core FieldList title field' \
        'FieldList {' 'title: String'
    require_token "$contact_edit" 'title: self.t("fields.a11y_contact_fields")' \
        'core-localized editable FieldList title'
    require_token "$success" 'title: t("fields.a11y_contact_fields")' \
        'core-localized read-only FieldList title'
    require_token "$schema" '"FieldList"' 'generated FieldList wire schema'
}

check_android() {
    [ -d "$ROOT/android" ] || return 0
    model='android/app/src/main/kotlin/app/vauchi/ui/coreui/Models.kt'
    renderer='android/app/src/main/kotlin/app/vauchi/ui/coreui/ScreenRenderer.kt'
    inline='android/app/src/main/kotlin/app/vauchi/ui/coreui/components/InlineConfirmComponent.kt'
    editable='android/app/src/main/kotlin/app/vauchi/ui/coreui/components/EditableTextComponent.kt'
    image='android/app/src/main/kotlin/app/vauchi/ui/coreui/components/ImageCircleComponent.kt'
    status='android/app/src/main/kotlin/app/vauchi/ui/coreui/components/StatusIndicatorComponent.kt'
    qr='android/app/src/main/kotlin/app/vauchi/ui/coreui/components/QrCodeComponent.kt'
    field_list='android/app/src/main/kotlin/app/vauchi/ui/coreui/components/FieldListComponent.kt'
    for file in "$model" "$renderer" "$inline" "$editable" "$image" "$status" "$qr" "$field_list"; do require_file "$file" || return 0; done
    require_tokens "$model" 'core-owned component field' \
        confirmActionId cancelActionId editText saveText cancelText \
        editActionId saveActionId cancelActionId editing statusLabel title
    require_tokens "$renderer" 'verbatim component forwarding' \
        'confirmActionId = component.confirmActionId' \
        'cancelActionId = component.cancelActionId' \
        'editActionId = component.editActionId' \
        'saveActionId = component.saveActionId' \
        'cancelActionId = component.cancelActionId' \
        'editing = component.editing' \
        'editActionId = component.editActionId' \
        'statusLabel = component.statusLabel' \
        'title = component.title' \
        'a11y = component.a11y'
    require_tokens "$inline" 'verbatim InlineConfirm contract' \
        confirmActionId cancelActionId confirmText cancelText
    require_tokens "$editable" 'verbatim EditableText contract' \
        editActionId saveActionId cancelActionId editText saveText cancelText editing
    forbid_regex "$inline" 'remember|mutableStateOf|ActionPressed\(actionId[[:space:]]*=.*componentId' \
        'generic confirmation must not own workflow state or derive action ids'
    forbid_regex "$editable" 'remember|mutableStateOf|ActionPressed\(actionId[[:space:]]*=.*componentId' \
        'generic editing must not own workflow state or derive action ids'
    require_tokens "$image" 'verbatim ImageCircle edit contract' \
        editActionId 'ActionPressed(actionId = editActionId)'
    forbid_regex "$image" 'actionId[[:space:]]*=[[:space:]]*"edit_avatar"|a11y[.]edit_avatar' \
        'ImageCircle must forward core edit id/copy, not name the domain action'
    require_tokens "$status" 'verbatim StatusIndicator label contract' statusLabel 'text = statusLabel'
    forbid_regex "$status" 'LocalizationManager|status[.](pending|in_progress|success|failed|warning)' \
        'StatusIndicator must not localize or derive its semantic label frontend-side'
    require_tokens "$qr" 'verbatim QrCode label/a11y contract' \
        'a11y?.label ?: label' 'contentDescription = accessibilityLabel'
    forbid_regex "$qr" 'contentDescription[[:space:]]*=[[:space:]]*localizationManager[.]t\("qr[.]a11y_label"\)|text[[:space:]]*=[[:space:]]*"Generating QR' \
        'QrCode must not replace core copy with a frontend catalog/literal string'
    require_token "$field_list" 'a11y?.label ?: title' \
        'verbatim FieldList localized group label'
    forbid_regex "$field_list" 'a11y[.]contact_fields|"(Contact fields|Fields \(Show/Hide\))"' \
        'FieldList must not invent or localize its title frontend-side'
}

check_apple_view() {
    repo="$1"
    inline="$2"
    editable="$3"
    image="$4"
    status="$5"
    qr="$6"
    field_list="$7"
    [ -d "$ROOT/$repo" ] || return 0
    require_file "$repo/$inline" || return 0
    require_file "$repo/$editable" || return 0
    require_file "$repo/$image" || return 0
    require_file "$repo/$status" || return 0
    require_file "$repo/$qr" || return 0
    require_file "$repo/$field_list" || return 0
    require_tokens "$repo/$inline" 'verbatim InlineConfirm contract' \
        component.confirmActionId component.cancelActionId \
        component.confirmText component.cancelText
    require_tokens "$repo/$editable" 'verbatim EditableText contract' \
        component.editActionId component.saveActionId component.cancelActionId \
        component.editText component.saveText component.cancelText component.editing
    forbid_regex "$repo/$inline" '@State|actionPressed\(actionId:[[:space:]]*".*component[.]id' \
        'generic confirmation must not own state or derive action ids'
    forbid_regex "$repo/$editable" '@State|actionPressed\(actionId:[[:space:]]*".*component[.]id' \
        'generic editing must not own edit state or derive action ids'
    require_tokens "$repo/$image" 'verbatim ImageCircle edit contract' \
        component.editActionId 'actionPressed(actionId: editActionId)'
    forbid_regex "$repo/$image" 'actionPressed\(actionId:[[:space:]]*"edit_avatar"|AvatarPreviewComponent' \
        'ImageCircle must forward core edit id and use wire-humble naming'
    require_token "$repo/$status" '.accessibilityValue(component.statusLabel)' \
        'verbatim StatusIndicator localized accessibility value'
    forbid_regex "$repo/$status" 'statusLabel\(for:|case[[:space:]]+[.]pending:[[:space:]]*"Pending"' \
        'StatusIndicator must not derive English labels from the status enum'
    require_token "$repo/$qr" 'component.a11y?.label ?? component.label ?? ""' \
        'verbatim QrCode localized accessibility fallback'
    forbid_regex "$repo/$qr" 'accessibility(Label|Hint)\([^\n]*("QR code|"Point the camera|localizationService[.]t\("qr[.]a11y_label")|Text\("Failed to generate QR code"\)' \
        'QrCode must not invent visible/accessibility copy frontend-side'
    require_token "$repo/$field_list" '.accessibilityLabel(component.a11y?.label ?? component.title)' \
        'verbatim FieldList localized group label'
    forbid_regex "$repo/$field_list" '"Contact fields"|localizationService[.]t\("fields[.]a11y_contact_fields"\)' \
        'FieldList must not invent or localize its title frontend-side'
}

check_swift_model() {
    [ -d "$ROOT/vauchi-platform-swift" ] || return 0
    file='vauchi-platform-swift/Sources/CoreUIModels/Models.swift'
    require_file "$file" || return 0
    require_tokens "$file" 'shared Apple core-owned component field' \
        confirmActionId cancelActionId editText saveText cancelText \
        editActionId saveActionId cancelActionId editing
    require_token "$file" 'public let editActionId: String?' \
        'shared Apple ImageCircle opaque edit action field'
    require_token "$file" 'public let statusLabel: String' \
        'shared Apple StatusIndicator localized label field'
    require_token "$file" 'public let label: String?' \
        'shared Apple QrCode localized label field'
    require_token "$file" 'public let title: String' \
        'shared Apple FieldList localized title field'
}

check_gtk() {
    gtk='gtk-display'
    [ -d "$ROOT/$gtk" ] || gtk='linux-gtk'
    [ -d "$ROOT/$gtk" ] || return 0
    dispatch="$gtk/src/core_ui/components/mod.rs"
    inline="$gtk/src/core_ui/components/inline_confirm.rs"
    editable="$gtk/src/core_ui/components/editable_text.rs"
    image="$gtk/src/core_ui/components/image_circle.rs"
    status="$gtk/src/core_ui/components/status_indicator.rs"
    qr="$gtk/src/core_ui/components/qr_code.rs"
    field_list="$gtk/src/core_ui/components/field_list.rs"
    for file in "$dispatch" "$inline" "$editable" "$image" "$status" "$qr" "$field_list"; do require_file "$file" || return 0; done
    require_tokens "$dispatch" 'verbatim typed component forwarding' \
        confirm_action_id cancel_action_id edit_action_id save_action_id editing status_label title
    require_tokens "$inline" 'verbatim InlineConfirm contract' \
        confirm_action_id cancel_action_id confirm_text cancel_text
    require_tokens "$editable" 'verbatim EditableText contract' \
        edit_action_id save_action_id cancel_action_id edit_text save_text cancel_text editing
    forbid_regex "$inline" 'format![[:space:]]*!?\(' \
        'generic confirmation must not synthesize action ids or copy with format!'
    forbid_regex "$editable" 'format![[:space:]]*!?\(' \
        'generic editing must not synthesize action ids or copy with format!'
    require_tokens "$image" 'verbatim ImageCircle edit contract' \
        edit_action_id 'action_id: action_id.clone()'
    forbid_regex "$image" '"edit_avatar"' \
        'ImageCircle must not hardcode its edit action id'
    require_tokens "$status" 'verbatim StatusIndicator label contract' status_label '.label(status_label)'
    forbid_regex "$status" 'i18n::|status[.](pending|in_progress|success|failed|warning)' \
        'StatusIndicator must not localize or derive its semantic label frontend-side'
    require_tokens "$qr" 'verbatim QrCode label/a11y contract' \
        '.or(label.as_deref())' 'Property::Label(accessible_label)'
    forbid_regex "$qr" 'Property::Label\("(QR|Scan QR)|Failed to generate QR code' \
        'QrCode must not derive an English accessible label from its mode'
    require_tokens "$field_list" 'verbatim FieldList localized group label' \
        'unwrap_or(title)' 'Property::Label(accessible_label)'
    forbid_regex "$field_list" 'Property::Label\("Fields"\)' \
        'FieldList must not invent an English title frontend-side'
}

check_qt() {
    qt='qt-display'
    [ -d "$ROOT/$qt" ] || qt='linux-qt'
    [ -d "$ROOT/$qt" ] || return 0
    inline="$qt/src/coreui/components/inlineconfirmcomponent.cpp"
    editable="$qt/src/coreui/components/editabletextcomponent.cpp"
    image="$qt/src/coreui/components/imagecirclecomponent.cpp"
    status="$qt/src/coreui/components/statusindicatorcomponent.cpp"
    qr="$qt/src/coreui/components/qrcodecomponent.cpp"
    field_list="$qt/src/coreui/components/fieldlistcomponent.cpp"
    for file in "$inline" "$editable" "$image" "$status" "$qr" "$field_list"; do require_file "$file" || return 0; done
    require_tokens "$inline" 'verbatim InlineConfirm JSON contract' \
        'data["confirm_action_id"]' 'data["cancel_action_id"]' \
        'data["confirm_text"]' 'data["cancel_text"]'
    require_tokens "$editable" 'verbatim EditableText JSON contract' \
        'data["edit_action_id"]' 'data["save_action_id"]' \
        'data["cancel_action_id"]' 'data["edit_text"]' \
        'data["save_text"]' 'data["cancel_text"]' 'data["editing"]'
    forbid_regex "$inline" 'inner\["action_id"\][[:space:]]*=.*(componentId|data\["id"\])' \
        'generic confirmation must not derive action ids from component id'
    forbid_regex "$editable" 'inner\["action_id"\][[:space:]]*=.*(componentId|data\["id"\])' \
        'generic editing must not derive action ids from component id'
    require_tokens "$image" 'verbatim ImageCircle JSON contract' \
        'data["edit_action_id"]' 'inner["action_id"] = editActionId'
    forbid_regex "$image" '"edit_avatar"' \
        'ImageCircle must not hardcode its edit action id'
    require_tokens "$status" 'verbatim StatusIndicator JSON contract' \
        'data["status_label"]' 'new QLabel(data["status_label"].toString())'
    forbid_regex "$status" 'tr_vauchi\("status[.]|QStringLiteral\("(Pending|In progress|Success|Failed|Warning)"' \
        'StatusIndicator must not derive English labels from the status enum'
    require_tokens "$qr" 'verbatim QrCode label/a11y contract' \
        'data["label"].toString()' 'container->setAccessibleName(labelText)'
    forbid_regex "$qr" 'tr_vauchi\("qr[.](scan|exchange[.]description)|No QR data|Failed to generate QR code|Invalid QR code dimensions' \
        'QrCode must not derive an accessible label from its mode'
    require_token "$field_list" 'container->setAccessibleName(data["title"].toString())' \
        'verbatim FieldList localized group label'
    forbid_regex "$field_list" 'tr_vauchi\("contact_card[.]fields"|setAccessibleName\("Fields"\)' \
        'FieldList must not invent or localize its title frontend-side'
}

check_windows() {
    # windows was renamed to windows-app (private#1234).
    win='windows-app'
    [ -d "$ROOT/$win" ] || win='windows'
    [ -d "$ROOT/$win" ] || return 0
    inline="$win/Vauchi/CoreUI/Components/InlineConfirmComponent.xaml.cs"
    editable="$win/Vauchi/CoreUI/Components/EditableTextComponent.xaml.cs"
    image="$win/Vauchi/CoreUI/Components/ImageCircleComponent.xaml.cs"
    status="$win/Vauchi/CoreUI/Components/StatusIndicatorComponent.xaml.cs"
    qr="$win/Vauchi/CoreUI/Components/QrCodeComponent.xaml.cs"
    field_list="$win/Vauchi/CoreUI/Components/FieldListComponent.xaml.cs"
    for file in "$inline" "$editable" "$image" "$status" "$qr" "$field_list"; do require_file "$file" || return 0; done
    require_tokens "$inline" 'verbatim InlineConfirm JSON contract' \
        '"confirm_action_id"' '"cancel_action_id"' '"confirm_text"' '"cancel_text"'
    require_tokens "$editable" 'verbatim EditableText JSON contract' \
        '"edit_action_id"' '"save_action_id"' '"cancel_action_id"' \
        '"edit_text"' '"save_text"' '"cancel_text"' '"editing"'
    forbid_regex "$inline" 'ActionPressed\([^)]*(_componentId|componentId|"(confirm|cancel))' \
        'generic confirmation must not derive or hardcode action ids'
    forbid_regex "$editable" 'ActionPressed\([^)]*(_componentId|componentId|"(edit|save|cancel))' \
        'generic editing must not derive or hardcode action ids'
    require_tokens "$image" 'verbatim ImageCircle JSON contract' \
        '"edit_action_id"' 'ActionPressed(_editActionId)'
    forbid_regex "$image" 'ActionPressed\("edit_avatar"\)|"Edit avatar"' \
        'ImageCircle must not hardcode its edit id or accessibility copy'
    require_tokens "$status" 'verbatim StatusIndicator JSON contract' \
        '"status_label"' 'StatusLabel.Text = statusLabel'
    forbid_regex "$status" 'Localizer[.]T\("status[.]|StatusLabel[.]Text[[:space:]]*=[[:space:]]*status([;[:space:]]|$)' \
        'StatusIndicator must not derive English labels from the status enum'
    require_token "$qr" 'AutomationProperties.SetName(this, label ?? "")' \
        'verbatim QrCode localized accessibility fallback'
    forbid_regex "$qr" 'AutomationProperties[.]SetName\(this,[[:space:]]*label[[:space:]]*[?][?][[:space:]]*"QR Code"' \
        'QrCode must not invent an English accessibility fallback'
    require_tokens "$field_list" 'verbatim FieldList localized group label' \
        'TryGetProperty("title"' 'AutomationProperties.SetName(this, title)'
    forbid_regex "$field_list" 'Localizer[.]T\("(fields|contact_card)[.]|SetName\(this,[[:space:]]*"Fields"\)' \
        'FieldList must not invent or localize its title frontend-side'
}

check_tui() {
    [ -d "$ROOT/tui" ] || return 0
    keys='tui/src/ui/widgets/key_mapping/component_keys.rs'
    renderer='tui/src/ui/widgets/screen_renderer/mod.rs'
    qr='tui/src/ui/widgets/screen_renderer/render_misc.rs'
    field_list='tui/src/ui/widgets/field_list.rs'
    for file in "$keys" "$renderer" "$qr" "$field_list"; do require_file "$file" || return 0; done
    require_tokens "$keys" 'verbatim terminal action forwarding' \
        confirm_action_id cancel_action_id edit_action_id save_action_id cancel_action_id
    require_tokens "$renderer" 'core-owned terminal copy/edit mode' \
        confirm_text cancel_text edit_text save_text editing edit_action_id status_label
    forbid_regex "$keys" 'format!\("(confirm|cancel|edit|save)_\{id\}' \
        'generic components must not synthesize action ids from component id'
    require_token "$keys" 'edit_action_id: Some(action_id)' \
        'verbatim ImageCircle edit action forwarding'
    forbid_regex "$keys" '"edit_avatar"' \
        'ImageCircle must not hardcode its edit action id'
    require_token "$renderer" 'status_label,' \
        'verbatim StatusIndicator localized label forwarding'
    require_token "$qr" 'let title = label.map(|value| format!(" {value} ")).unwrap_or_default()' \
        'verbatim QrCode localized title'
    forbid_regex "$qr" '" (QR Code|Scan QR Code) "|QR code too large to render|QR mode not supported' \
        'QrCode must not derive an English title from its mode'
    require_tokens "$field_list" 'verbatim FieldList localized panel title' \
        'pub title:' 'format!(" {} ", self.title)' '.title(panel_title)'
    forbid_regex "$field_list" 'Fields \(Show/Hide\)|Fields \(Per Group\)|" Fields "' \
        'FieldList must not derive an English panel title from visibility mode'
}

check_web() {
    [ -d "$ROOT/web-demo" ] || return 0
    types='web-demo/src/types/core.ts'
    inline='web-demo/src/core-ui/components/InlineConfirmComponent.tsx'
    editable='web-demo/src/core-ui/components/EditableTextComponent.tsx'
    image='web-demo/src/core-ui/components/ImageCircleComponent.tsx'
    status='web-demo/src/core-ui/components/StatusIndicatorComponent.tsx'
    qr='web-demo/src/core-ui/components/QrCodeComponent.tsx'
    field_list='web-demo/src/core-ui/components/FieldListComponent.tsx'
    for file in "$types" "$inline" "$editable" "$image" "$status" "$qr" "$field_list"; do require_file "$file" || return 0; done
    require_tokens "$types" 'web core-owned component field' \
        confirm_action_id cancel_action_id edit_text save_text cancel_text \
        edit_action_id save_action_id cancel_action_id editing status_label title
    require_tokens "$inline" 'verbatim InlineConfirm contract' \
        props.confirm_action_id props.cancel_action_id props.confirm_text props.cancel_text
    require_tokens "$editable" 'verbatim EditableText contract' \
        props.edit_action_id props.save_action_id props.cancel_action_id \
        props.edit_text props.save_text props.cancel_text props.editing
    forbid_regex "$inline" '(confirm|cancel|edit|save)_[$][{]props[.]id[}]|createSignal|useState' \
        'generic confirmation must not derive ids or own workflow state'
    forbid_regex "$editable" '(confirm|cancel|edit|save)_[$][{]props[.]id[}]|createSignal|useState' \
        'generic editing must not derive ids or own edit state'
    require_tokens "$image" 'verbatim ImageCircle edit contract' \
        props.edit_action_id 'action_id: actionId'
    forbid_regex "$image" 'action_id:[[:space:]]*"edit_avatar"|"Edit avatar"' \
        'ImageCircle must not hardcode its edit id or accessibility copy'
    require_tokens "$status" 'verbatim StatusIndicator label contract' \
        status_label 'props.status_label'
    forbid_regex "$status" '>\{props[.]status\}<' \
        'StatusIndicator must render core status_label, not the enum discriminant'
    require_tokens "$qr" 'verbatim QrCode label/a11y contract' \
        'props.a11y?.label ?? props.label ?? undefined' \
        'alt={props.a11y?.label ?? props.label ?? ""}'
    forbid_regex "$qr" 'alt="QR Code"|>Point camera at QR code<' \
        'QrCode must not invent English visible/accessibility copy from its mode'
    require_token "$field_list" 'props.a11y?.label ?? props.title' \
        'verbatim FieldList localized group label'
    forbid_regex "$field_list" '"Contact fields"|"Fields \(Show/Hide\)"' \
        'FieldList must not invent an English title frontend-side'
}

check_core
check_android
check_apple_view ios \
    'Vauchi/CoreUI/Components/InlineConfirmView.swift' \
    'Vauchi/CoreUI/Components/EditableTextView.swift' \
    'Vauchi/CoreUI/Components/ImageCircleView.swift' \
    'Vauchi/CoreUI/Components/StatusIndicatorView.swift' \
    'Vauchi/CoreUI/Components/QrCodeView.swift' \
    'Vauchi/CoreUI/Components/FieldListView.swift'
check_apple_view macos \
    'Vauchi/CoreUI/Components/InlineConfirmComponentView.swift' \
    'Vauchi/CoreUI/Components/EditableTextComponentView.swift' \
    'Vauchi/CoreUI/Components/ImageCircleComponentView.swift' \
    'Vauchi/CoreUI/Components/StatusIndicatorComponentView.swift' \
    'Vauchi/CoreUI/Components/QrCodeComponentView.swift' \
    'Vauchi/CoreUI/Components/FieldListComponentView.swift'
check_swift_model
check_gtk
check_qt
check_windows
check_tui
check_web

if [ "$failures" -ne 0 ]; then
    printf 'core-owned-generic-components: FAIL — %d violation(s) across %d checks\n' \
        "$failures" "$checks" >&2
    exit 1
fi

printf 'core-owned-generic-components: OK — %d strict contract checks passed\n' "$checks"
