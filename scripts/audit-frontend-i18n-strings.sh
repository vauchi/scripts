#!/usr/bin/env bash
# SPDX-FileCopyrightText: 2026 Mattia Egloff <mattia.egloff@pm.me>
#
# SPDX-License-Identifier: GPL-3.0-or-later

# audit-frontend-i18n-strings.sh — Hardcoded-English ratchet over the
# frontend repos that do not yet have a dedicated i18n string lint.
#
# Existing dedicated ratchets (left untouched):
#   - core/vauchi-app/src/ui          -> audit-ui-literals.sh
#   - ios/ and macos/ SwiftUI Text()  -> check-text-literal-count.sh
#
# This script covers the remaining frontends selected in
# 2026-07-07-code-quality-debt-sweep:
#   - android/        Kotlin Compose Text()
#   - windows/        XAML Content/Text/PlaceholderText
#   - linux-qt/       C++ Qt user-facing strings
#   - linux-gtk/      Rust GTK user-facing strings
#   - tui/            Rust ratatui Paragraph/Line/Span
#   - cli/            Rust clap help/about and println!/eprintln! strings
#
# Usage:
#   audit-frontend-i18n-strings.sh [workspace_root]
#       Emit JSON snapshot on stdout.
#   audit-frontend-i18n-strings.sh --check <baseline.json> [workspace_root]
#       Ratchet mode. Exit 1 if any frontend total EXCEEDS baseline.
#
# Android source discovery also requires Python 3's standard library.
# Shell utilities remain BSD/GNU/BusyBox-portable.

set -euo pipefail

MODE=snapshot
BASELINE=""
if [ "${1:-}" = "--check" ]; then
    MODE=check
    BASELINE="${2:?--check requires a baseline.json path}"
    shift 2
fi

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT="${1:-$(cd "$SCRIPT_DIR/../.." && pwd)}"
[ -d "$ROOT" ] || { echo "audit-frontend-i18n-strings: bad workspace root: $ROOT" >&2; exit 2; }

# A string literal looks like user-visible English when:
#   - it starts with a letter
#   - it contains at least one lowercase letter
#   - it is at least 2 characters long
#   - it is not a locale key (no '.')
#   - it is not only whitespace / punctuation / digits
looks_like_english() {
    case "$1" in
        # empty
        "") return 1 ;;
        # starts with non-letter
        [A-Za-z]*) ;;
        *) return 1 ;;
    esac
    # must contain a lowercase letter
    case "$1" in
        *[a-z]*) ;;
        *) return 1 ;;
    esac
    # must be at least 2 chars
    [ "${#1}" -ge 2 ] || return 1
    # locale keys contain a dot
    case "$1" in
        *.*) return 1 ;;
    esac
    return 0
}

# linux-qt has many non-user-visible strings that pass the generic English
# heuristic: CSS snippets, icon names, object-name identifiers, D-Bus method
# names and date/time format patterns. Treat them as infrastructure.
is_linux_qt_infrastructure_string() {
    case "$1" in
        # CSS style/template snippets
        *";"*) return 0 ;;
        # printf / Q_ARG placeholders
        *%[0-9]*) return 0 ;;
        # Freedesktop icon / theme names
        emblem-*|dialog-*|view-*) return 0 ;;
        # D-Bus method names
        RegisterAdvertisement*|UnregisterAdvertisement*) return 0 ;;
        # Date/time format patterns
        yyyy*|*yyyy*|*MM-dd*|*hh:mm*) return 0 ;;
        # CSS font-family templates that get truncated by the line matcher
        font-family*|*\\) return 0 ;;
    esac
    # Object-name identifiers: lowercase letters/digits/underscores/hyphens,
    # no spaces. Qt test/a11y handles commonly use either separator.
    if printf '%s' "$1" | grep -Eq '^[a-z_][a-z0-9_-]*$'; then
        return 0
    fi
    return 1
}

# A Core protocol name (ReplaceSurface, Text) or a key sequence (Ctrl+K,
# Alt+Down): one token, no spaces.
is_linux_qt_key_string() {
    printf '%s' "$1" | grep -Eq '^([A-Z][A-Za-z0-9]*|(Ctrl|Alt|Shift|Meta)(\+[A-Za-z0-9]+)+)$'
}

# Extract the contents of every double-quoted string literal from stdin.
# Treats backslash-escaped quotes (\") as part of the literal so CSS
# templates like "font-family: \"%1\";" are extracted whole.
count_strings_from_stdin() {
    awk '
        {
            rest = $0
            while (match(rest, /"([^"]|\\")*"/)) {
                s = substr(rest, RSTART + 1, RLENGTH - 2)
                print s
                rest = substr(rest, RSTART + RLENGTH)
            }
        }
    '
}

# Count lines where a line matching $2 contains a string that looks like English.
# $1 = file, $2 = POSIX ERE regex
count_english_strings() {
    local matches scan_status
    # -o emits only the matched text, so we extract string literals from the
    # attribute/macro call itself rather than every quoted substring on the line.
    if matches=$(grep -aE -o "$2" "$1"); then
        :
    else
        scan_status=$?
        [ "$scan_status" -eq 1 ] || return "$scan_status"
    fi
    printf '%s\n' "$matches" | count_strings_from_stdin | while IFS= read -r s; do
        if looks_like_english "$s"; then
            echo "$s"
        fi
    done | wc -l | tr -d ' '
}

# ── Android Kotlin ──────────────────────────────────────────────────────────
# Direct Compose Text("Foo") or Text(text = "Foo").
count_android() {
    local n=0 tmp_list f t
    tmp_list=$(mktemp) || return 2
    if ! python3 - "$ROOT" > "$tmp_list" <<'PY'
import os
from pathlib import Path
import re
import sys


def fail_walk(error):
    raise error


def sources(root, required=False, omit=None):
    if root.is_symlink() or not root.is_dir():
        if required:
            raise ValueError(f"no regular production source root: {root}")
        return []
    result = []
    for directory, children, files in os.walk(root, onerror=fail_walk):
        parent = Path(directory)
        for name in children[:]:
            child = parent / name
            if child == omit:
                children.remove(name)
            elif child.is_symlink():
                if required:
                    raise ValueError(f"linked source directory: {child}")
                children.remove(name)
        for name in sorted(files):
            path = parent / name
            if path.is_symlink():
                if required:
                    raise ValueError(f"linked source file: {path}")
                continue
            if path.suffix != ".kt" or any(
                part in path.as_posix() for part in ("/src/test/", "/src/androidTest/")
            ):
                continue
            if not path.is_file():
                raise ValueError(f"nonregular source file: {path}")
            path.read_text(encoding="utf-8")
            result.append(path)
    if required and not result:
        raise ValueError(f"no Kotlin production sources: {root}")
    return result


def module_sources(module):
    for root in (module, module / "src", module / "src/main"):
        if root.is_symlink() or not root.is_dir():
            raise ValueError(f"no regular production source root: {root}")
    return sources(module / "src/main", required=True)


try:
    workspace = Path(sys.argv[1]).absolute()
    app = next((candidate for candidate in (workspace / "android-app", workspace / "android")
                if candidate.is_dir()), None)
    if app is None and (workspace / "app").is_dir():
        app = workspace
    settings = (app or workspace) / "settings.gradle.kts"
    settings_text = settings.read_text(encoding="utf-8") if settings.exists() else ""
    settings_text = re.sub(r"//[^\n]*", "", settings_text)
    standalone = workspace.name == "android-display" or re.search(
        r'^\s*rootProject\.name\s*=\s*"android-display"\s*$', settings_text, re.MULTILINE
    )
    independent = None
    if "VAUCHI_ANDROID_DISPLAY_ROOT" in os.environ:
        declared = os.environ["VAUCHI_ANDROID_DISPLAY_ROOT"]
        if not declared:
            raise ValueError("empty required display source checkout")
        independent = Path(declared).absolute()
    elif (workspace / "android-display").exists() or (workspace / "android-display").is_symlink():
        independent = workspace / "android-display"
    elif standalone:
        independent = workspace
    selected = module_sources(independent) if independent is not None else []
    if app is not None:
        in_place = app / "display"
        declared_in_place = '":display"' in settings_text
        if declared_in_place:
            module_sources(in_place)
        selected += sources(app, omit=in_place if independent is not None and not declared_in_place else None)
    for path in sorted(set(selected)):
        sys.stdout.buffer.write(os.fsencode(path) + b"\0")
except (OSError, UnicodeError, ValueError) as error:
    print(f"audit-frontend-i18n-strings: Android source error: {error}", file=sys.stderr)
    sys.exit(2)
PY
    then
        rm -f "$tmp_list"
        return 2
    fi
    while IFS= read -r -d '' f; do
        # Match Text("...") or Text(text = "..."), excluding stringResource.
        if ! t=$(count_english_strings "$f" 'Text\((text[[:space:]]*=[[:space:]]*)?"[^"]*"\)'); then
            echo "audit-frontend-i18n-strings: cannot scan Android source: $f" >&2
            rm -f "$tmp_list"
            return 2
        fi
        n=$((n + t))
    done < "$tmp_list"
    rm -f "$tmp_list"
    echo "$n"
}

# ── Windows XAML ────────────────────────────────────────────────────────────
count_windows() {
    # windows was renamed to windows-app (private#1234).
    local dir="$ROOT/windows-app"
    [ -d "$dir" ] || dir="$ROOT/windows"
    [ -d "$dir" ] || { echo 0; return; }
    local n=0
    tmp_list=$(mktemp)
    find "$dir" -name '*.xaml' -type f -print > "$tmp_list"
    while IFS= read -r f; do
        # Match Content="..." Text="..." PlaceholderText="..." Header="..."
        t=$(count_english_strings "$f" '(Content|Text|PlaceholderText|Header|ToolTipService\.ToolTip)="[^"]*"')
        n=$((n + t))
    done < "$tmp_list"
    rm -f "$tmp_list"
    echo "$n"
}

# ── linux-qt C++ ────────────────────────────────────────────────────────────
count_linux_qt() {
    local dir="$ROOT/qt-display"
    [ -d "$dir" ] || dir="$ROOT/linux-qt"
    [ -d "$dir" ] || { echo 0; return; }
    local n=0
    tmp_list=$(mktemp)
    find "$dir" \( -name '*.cpp' -o -name '*.h' -o -name '*.hpp' \) -type f -print > "$tmp_list"
    while IFS= read -r f; do
        # Skip test code: test fixtures are not shipped UI.
        case "$f" in */tests/*|*/test/*) continue ;; esac
        # QStringLiteral fallback in tr_vauchi: one-word protocol keys and key
        # sequences are skipped there, since the shell decodes Core's commands
        # by name (vauchi/private#543).
        t1=$(grep -E -o 'QStringLiteral\([[:space:]]*"[^"]*"' "$f" 2>/dev/null | count_strings_from_stdin | while IFS= read -r s; do
            if looks_like_english "$s" && ! is_linux_qt_infrastructure_string "$s" \
                && ! is_linux_qt_key_string "$s"; then
                echo "$s"
            fi
        done | wc -l | tr -d ' ')
        # Direct setters always receive copy, so a one-word label still counts.
        t2=$(grep -E -o '(setText|setWindowTitle|setPlaceholderText)\([[:space:]]*"[^"]*"' "$f" 2>/dev/null | count_strings_from_stdin | while IFS= read -r s; do
            if looks_like_english "$s" && ! is_linux_qt_infrastructure_string "$s"; then
                echo "$s"
            fi
        done | wc -l | tr -d ' ')
        n=$((n + t1 + t2))
    done < "$tmp_list"
    rm -f "$tmp_list"
    echo "$n"
}

# ── linux-gtk Rust ──────────────────────────────────────────────────────────
count_linux_gtk() {
    local dir="$ROOT/gtk-display"
    [ -d "$dir" ] || dir="$ROOT/linux-gtk"
    [ -d "$dir" ] || { echo 0; return; }
    local n=0
    tmp_list=$(mktemp)
    find "$dir" -name '*.rs' -type f -print > "$tmp_list"
    while IFS= read -r f; do
        # .label("...") .title("...") .placeholder_text("...")
        t=$(count_english_strings "$f" '\.(label|title|placeholder_text)\([[:space:]]*&?"[^"]*"')
        n=$((n + t))
    done < "$tmp_list"
    rm -f "$tmp_list"
    echo "$n"
}

# ── TUI Rust ────────────────────────────────────────────────────────────────
count_tui() {
    # tui was renamed to tui-display (private#1233).
    local dir="$ROOT/tui-display"
    [ -d "$dir" ] || dir="$ROOT/tui"
    [ -d "$dir" ] || { echo 0; return; }
    local n=0
    tmp_list=$(mktemp)
    find "$dir" -name '*.rs' -type f -print > "$tmp_list"
    while IFS= read -r f; do
        # Paragraph::new("...") Line::from("...") Span::raw("...")
        t=$(count_english_strings "$f" '(Paragraph::new|Line::from|Span::raw)\([[:space:]]*"[^"]*"')
        n=$((n + t))
    done < "$tmp_list"
    rm -f "$tmp_list"
    echo "$n"
}

# ── CLI Rust ────────────────────────────────────────────────────────────────
count_cli() {
    # cli was renamed to cli-display (private#1233).
    local dir="$ROOT/cli-display"
    [ -d "$dir" ] || dir="$ROOT/cli"
    [ -d "$dir" ] || { echo 0; return; }
    local n=0
    tmp_list=$(mktemp)
    find "$dir" -name '*.rs' -type f -print > "$tmp_list"
    while IFS= read -r f; do
        # clap about/help/long_about attributes
        t1=$(count_english_strings "$f" '(about|help|long_about)[[:space:]]*=[[:space:]]*"[^"]*"')
        # println!/eprintln! with a literal string starting the format
        t2=$(count_english_strings "$f" '(println|eprintln)!\([[:space:]]*"[^"]*"')
        n=$((n + t1 + t2))
    done < "$tmp_list"
    rm -f "$tmp_list"
    echo "$n"
}

android=$(count_android) || exit 2
windows=$(count_windows)
linux_qt=$(count_linux_qt)
linux_gtk=$(count_linux_gtk)
tui=$(count_tui)
cli=$(count_cli)
total=$((android + windows + linux_qt + linux_gtk + tui + cli))

json=$(printf '{
  "schema_version": 1,
  "totals": {
    "android": %d,
    "windows": %d,
    "linux_qt": %d,
    "linux_gtk": %d,
    "tui": %d,
    "cli": %d,
    "total": %d
  }
}\n' "$android" "$windows" "$linux_qt" "$linux_gtk" "$tui" "$cli" "$total")

if [ "$MODE" = "snapshot" ]; then
    printf '%s\n' "$json"
    exit 0
fi

# ── check mode ──────────────────────────────────────────────────────────────
[ -f "$BASELINE" ] || { echo "audit-frontend-i18n-strings: baseline not found: $BASELINE" >&2; exit 2; }

get_total() { # $1 = json-string, $2 = key
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

rc=0
for key in android windows linux_qt linux_gtk tui cli total; do
    cur=$(get_total "$json" "$key")
    base=$(get_total "$(cat "$BASELINE")" "$key")
    base=${base:-0}
    if [ "$cur" -gt "$base" ]; then
        echo "audit-frontend-i18n-strings RATCHET: $key rose to $cur (baseline $base) — new hardcoded English string(s) detected. Route user-visible text through the locale system." >&2
        rc=1
    fi
done
if [ "$rc" -eq 0 ]; then
    echo "audit-frontend-i18n-strings: OK (android=$android windows=$windows linux_qt=$linux_qt linux_gtk=$linux_gtk tui=$tui cli=$cli total=$total, all <= baseline)"
fi
exit "$rc"
