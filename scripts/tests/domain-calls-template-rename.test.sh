#!/usr/bin/env bash
# SPDX-FileCopyrightText: 2026 Mattia Egloff <mattia.egloff@pm.me>
#
# SPDX-License-Identifier: GPL-3.0-or-later
#
# .domain-calls-job copies the repository into a one-repo workspace under
# its project name, and the audit looks for it under its workspace
# directory. ADR-078 renames linux-gtk and linux-qt in GitLab before the
# workspace directories follow (private#1029): copied as gtk-display or
# qt-display the repository is an absent sibling, counts zero, and the
# ratchet passes whatever the source holds.

set -u

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
TEMPLATE="$ROOT/ci-templates/domain-calls.yml"
AUDIT="$ROOT/scripts/audit-frontend-domain-calls.sh"

pass=0
fail=0
check() {
    name="$1"; want="$2"; got="$3"
    if [ "$want" = "$got" ]; then
        pass=$((pass + 1)); printf '  PASS %s\n' "$name"
    else
        fail=$((fail + 1))
        printf '  FAIL %s\n    want: %s\n    got:  %s\n' "$name" "$want" "$got" >&2
    fi
}

work=$(mktemp -d)
# The job's lines from the directory choice to the copy, as plain sh.
awk '/case "\$CI_PROJECT_NAME" in/ { on = 1 } on { sub(/^      /, ""); print } on && /cp -R "\$CI_PROJECT_DIR"/ { exit }' \
    "$TEMPLATE" | sed 's|^WS=/tmp/ws$|WS="$WORK/ws"|' > "$work/copy.sh"

check "the job copies the repository into the workspace" "1" \
    "$(grep -c 'cp -R "\$CI_PROJECT_DIR"' "$work/copy.sh")"

copied_as() {
    rm -rf "$work/ws" "$work/project"
    mkdir -p "$work/project/src"
    : > "$work/project/src/marker"
    WORK="$work" CI_PROJECT_NAME="$1" CI_PROJECT_DIR="$work/project" sh "$work/copy.sh" >/dev/null 2>&1
    find "$work/ws" -name marker 2>/dev/null | sed "s|^$work/ws/||"
}

check "gtk-display is copied where the audit looks for the GTK shell" \
    "linux-gtk/src/marker" "$(copied_as gtk-display)"
check "qt-display is copied where the audit looks for the Qt shell" \
    "linux-qt/src/marker" "$(copied_as qt-display)"
check "linux-qt keeps its directory" "linux-qt/src/marker" "$(copied_as linux-qt)"
# ADR-078 step 4 renames windows to windows-app (private#1234); the audit
# reads the Windows shell in windows/ only.
check "windows-app is copied where the audit looks for the Windows shell" \
    "windows/src/marker" "$(copied_as windows-app)"
check "windows keeps its directory" "windows/src/marker" "$(copied_as windows)"
check "any other repository keeps its project name" "tui/src/marker" "$(copied_as tui)"

# Whatever directory the job picks, the audit must count the copy: the
# audit reads either name, so the mapping above can go with no change here.
counted_from() {
    rm -rf "$work/ws" "$work/project"
    mkdir -p "$work/project/src"
    printf 'void f() { validateContact(payload); }\n' > "$work/project/src/app.cpp"
    printf 'fn f(e: &Engine) { e.save_contact(c); }\n' > "$work/project/src/app.rs"
    WORK="$work" CI_PROJECT_NAME="$1" CI_PROJECT_DIR="$work/project" sh "$work/copy.sh" >/dev/null 2>&1
    bash "$AUDIT" "$work/ws" | sed -n "s/.*\"$2\": *\([0-9]*\).*/\1/p"
}

check "the audit counts the GTK shell where the job copied gtk-display" "1" \
    "$(counted_from gtk-display domain_calls_linux_gtk)"
check "the audit counts the Qt shell where the job copied qt-display" "1" \
    "$(counted_from qt-display domain_calls_linux_qt)"

windows_counted_from() {
    rm -rf "$work/ws" "$work/project"
    mkdir -p "$work/project/Vauchi"
    printf 'class A { void F(Engine e) { e.SaveContact(c); } }\n' > "$work/project/Vauchi/App.cs"
    WORK="$work" CI_PROJECT_NAME="$1" CI_PROJECT_DIR="$work/project" sh "$work/copy.sh" >/dev/null 2>&1
    bash "$AUDIT" "$work/ws" | sed -n 's/.*"domain_calls_windows": *\([0-9]*\).*/\1/p'
}

check "the audit counts the Windows shell where the job copied windows-app" "1" \
    "$(windows_counted_from windows-app)"
check "the audit counts the Windows shell where the job copied windows" "1" \
    "$(windows_counted_from windows)"

rm -rf "$work"

printf '\n%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
