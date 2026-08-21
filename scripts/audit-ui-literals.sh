#!/usr/bin/env bash
# SPDX-FileCopyrightText: 2026 Mattia Egloff <mattia.egloff@pm.me>
#
# SPDX-License-Identifier: GPL-3.0-or-later

# audit-ui-literals.sh — hardcoded-English ratchet over core's
# ScreenModel builders (M3 S2 of 2026-07-03-core-screens-bypass-i18n,
# design D3.4). Counts double-quoted string literals starting with a
# letter in presentational field positions of production code under
# core/vauchi-app/src/ui — the strings a non-English user would see
# untranslated. The i18n threading slices (M3 S3–S6) burn the count
# down; this gate keeps it from ever rising again.
#
# Counted positions (JSON counters):
#   ui_literal_titles — `title:` initialized with a string literal
#   ui_literal_labels — `label:` / `subtitle:` / `detail:` / `hint:` /
#                       `placeholder:` / `content:` initialized with a
#                       string literal (covers the wire-level A11y
#                       struct's label/hint fields at their inline
#                       construction sites)
#   ui_literal_messages — `message:` initialized with a string literal
#                       (toast/alert body copy — the ShowToast and
#                       ShowAlert sentences a user reads verbatim)
#   ui_literal_total  — sum
#
# Deliberately NOT counted:
#   - `get_string(...)` / any non-literal initializer (the fix state)
#   - `id:` / `screen_id:` / `value:` positions — ids are wire
#     vocabulary, values are data, neither is display copy
#   - `#[cfg(test)]` blocks (production ratchet only; ui files keep
#     their test modules last, and the scan stops at the attribute)
#
# Usage:
#   audit-ui-literals.sh [workspace_root]
#       Emit the JSON snapshot on stdout. Exit 0 (the JSON is the
#       result); exit 2 only on internal error (bad workspace root).
#   audit-ui-literals.sh --check <baseline.json> [workspace_root]
#       Ratchet mode. Compare each current total against the baseline;
#       exit 1 if ANY total EXCEEDS its baseline value (a regression).
#       Counts at or below baseline pass (exit 0). Absent core tree
#       counts 0 ≤ baseline and passes (single-repo CI safety).
#
# Default workspace_root: two levels up from this script.
#
# Portability: POSIX shell + BSD/GNU/BusyBox-portable utilities only.
# No grep -P, no bash arrays, no GNU --include/--exclude, no mapfile.

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
[ -d "$ROOT" ] || { echo "audit-ui-literals: bad workspace root: $ROOT" >&2; exit 2; }

UI_DIR="$ROOT/core/vauchi-app/src/ui"

# Count literal-initialized presentational fields in production regions
# of one file. `kind` selects the field-name alternation. The awk state
# machine stops counting at the first `#[cfg(test)]` attribute — ui
# files keep their test module last (pinned by the sentinel suite).
#
# Strings that look like locale keys (contain a '.') are excluded — the
# desired end-state for i18n threading is `title: "some.key".into()`, not
# a hardcoded English literal.
count_kind() { # $1 = file, $2 = "title" | "label" | "message"
    awk -v kind="$2" '
        /^#\[cfg\(test\)\]/ { intest = 1 }
        intest { next }
        # `message:` holds whole sentences, so its key test is exact
        # rather than "contains a dot": the dot rule the other kinds
        # use would wave through every sentence ending in a period.
        kind == "message" {
            if ($0 ~ "(^|[^_a-zA-Z])message:[[:space:]]*(Some\\()?\"") {
                s = $0
                sub(/^.*message:[[:space:]]*/, "", s)
                sub(/^Some\(/, "", s)
                sub(/^"/, "", s)
                sub(/".*$/, "", s)
                if (s ~ /^[A-Za-z]/ && s !~ /^[a-z0-9_]+(\.[a-z0-9_]+)+$/) n++
            }
            next
        }
        {
            if (kind == "title")
                pat = "(^|[^_a-zA-Z])title:[[:space:]]*(Some\\()?\"[A-Za-z][^.\"]*\""
            else
                pat = "(^|[^_a-zA-Z])(label|subtitle|detail|hint|placeholder|content):[[:space:]]*(Some\\()?\"[A-Za-z][^.\"]*\""
            if ($0 ~ pat) n++
        }
        END { print n + 0 }
    ' "$1"
}

titles=0
labels=0
messages=0
if [ -d "$UI_DIR" ]; then
    # find -print + read loop: portable, no process-substitution needs.
    tmp_list=$(mktemp)
    find "$UI_DIR" -name '*.rs' -type f -print > "$tmp_list"
    while IFS= read -r f; do
        t=$(count_kind "$f" title)
        l=$(count_kind "$f" label)
        m=$(count_kind "$f" message)
        titles=$((titles + t))
        labels=$((labels + l))
        messages=$((messages + m))
    done < "$tmp_list"
    rm -f "$tmp_list"
fi
total=$((titles + labels + messages))

json=$(printf '{
  "schema_version": 1,
  "totals": {
    "ui_literal_titles": %d,
    "ui_literal_labels": %d,
    "ui_literal_messages": %d,
    "ui_literal_total":  %d
  }
}\n' "$titles" "$labels" "$messages" "$total")

if [ "$MODE" = "snapshot" ]; then
    printf '%s\n' "$json"
    exit 0
fi

# ── check mode ──────────────────────────────────────────────────────
[ -f "$BASELINE" ] || { echo "audit-ui-literals: baseline not found: $BASELINE" >&2; exit 2; }

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
for key in ui_literal_titles ui_literal_labels ui_literal_messages ui_literal_total; do
    cur=$(get_total "$json" "$key")
    base=$(get_total "$(cat "$BASELINE")" "$key")
    base=${base:-0}
    if [ "$cur" -gt "$base" ]; then
        echo "audit-ui-literals RATCHET: $key rose to $cur (baseline $base) — new hardcoded English in core/vauchi-app/src/ui. Use get_string(locale, \"<key>\") + a locales entry instead." >&2
        rc=1
    fi
done
if [ "$rc" -eq 0 ]; then
    echo "audit-ui-literals: OK (titles=$titles labels=$labels messages=$messages total=$total, all <= baseline)"
fi
exit "$rc"
