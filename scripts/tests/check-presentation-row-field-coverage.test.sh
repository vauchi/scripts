#!/usr/bin/env bash
# SPDX-FileCopyrightText: 2026 Mattia Egloff <mattia.egloff@pm.me>
# SPDX-License-Identifier: GPL-3.0-or-later
#
# The gate must fail when a shell stops reading a row field, and pass when
# it reads it. An earlier revision matched the bare word, so deleting
# `row.subtitle` left the binding name `subtitle` behind and the check
# could not fail at all — hence a test that deletes a read and demands red.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
SCRIPT="$SCRIPT_DIR/../check-presentation-row-field-coverage.py"
ROOT=$(mktemp -d)
trap 'rm -rf "$ROOT"' EXIT

SHELL_FILES=(
    "ios/Vauchi/CoreUI/PresentationNodeView.swift"
    "macos/Vauchi/CoreUI/PresentationNodeView.swift"
    "android/app/src/main/kotlin/app/vauchi/ui/presentation/PresentationNodeRenderer.kt"
    "tui/src/ui/presentation_renderer/nodes.rs"
    "gtk-display/src/core_ui/generic_surface/collections.rs"
    "qt-display/src/coreui/presentationsurface.cpp"
    "windows/Vauchi/CoreUI/PresentationSurfaceCollections.cs"
    "web-demo/src/presentation/PresentationNodeRenderer.tsx"
)

write_struct() {
    mkdir -p "$ROOT/core/vauchi-core/src/platform/presentation/surface"
    cat >"$ROOT/core/vauchi-core/src/platform/presentation/surface/nodes.rs" <<'EOF'
pub struct PresentationRow {
    pub title: String,
    pub subtitle: Option<String>,
}
EOF
}

# $1: when non-empty, that shell path omits the `.subtitle` read.
write_shells() {
    omit="${1:-}"
    for f in "${SHELL_FILES[@]}"; do
        mkdir -p "$ROOT/$(dirname "$f")"
        printf 'render(row.title)\n' >"$ROOT/$f"
        if [ "$f" != "$omit" ]; then
            printf 'render(row.subtitle)\n' >>"$ROOT/$f"
        else
            # The word survives as a local binding — the shape that fooled
            # the first revision of the matcher.
            printf 'let subtitle = none\n' >>"$ROOT/$f"
        fi
    done
}

run_check() {
    exemptions="${1:-}"
    if [ -n "$exemptions" ]; then
        python3 "$SCRIPT" --workspace "$ROOT" --exemptions "$exemptions" >/dev/null 2>&1
    else
        python3 "$SCRIPT" --workspace "$ROOT" --exemptions /dev/null >/dev/null 2>&1
    fi
}

fail() {
    printf 'FAIL: %s\n' "$1" >&2
    exit 1
}

write_struct

# 1. Every shell reads every field.
write_shells ""
printf '{}\n' >"$ROOT/empty.json"
run_check "$ROOT/empty.json" || fail "expected pass when every shell reads every field"

# 2. One shell stops reading one field.
write_shells "ios/Vauchi/CoreUI/PresentationNodeView.swift"
if run_check "$ROOT/empty.json"; then
    fail "expected failure when iOS stops reading .subtitle"
fi

# 3. That drop, exempted, passes again.
cat >"$ROOT/exempt.json" <<'EOF'
{ "ios": { "subtitle": "deliberate for this test" } }
EOF
run_check "$ROOT/exempt.json" || fail "expected pass once the drop is exempted"

# 4. tui became tui-display (private#1233): a workspace that has followed is
# read under the new name, and a drop there is still caught.
write_shells ""
mv "$ROOT/tui" "$ROOT/tui-display"
run_check "$ROOT/empty.json" || fail "expected pass when tui reads every field under tui-display"
printf 'render(row.title)\n' >"$ROOT/tui-display/src/ui/presentation_renderer/nodes.rs"
if run_check "$ROOT/empty.json"; then
    fail "expected failure when tui-display stops reading .subtitle"
fi

printf 'check-presentation-row-field-coverage: OK (5 cases)\n'
