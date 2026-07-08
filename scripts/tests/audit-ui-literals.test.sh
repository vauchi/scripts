#!/usr/bin/env bash
# SPDX-FileCopyrightText: 2026 Mattia Egloff <mattia.egloff@pm.me>
#
# SPDX-License-Identifier: GPL-3.0-or-later

# Sentinel regression suite for audit-ui-literals.sh — the hardcoded-
# English ratchet over core's ScreenModel builders (M3 S2 of
# 2026-07-03-core-screens-bypass-i18n, design D3.4).
#
# Per CC-20 / CC-21 these tests are NON-tautological: each builds a tiny
# synthetic core/vauchi-app/src/ui tree in a temp workspace, plants known
# sentinel lines, runs the real script, and asserts the gate COUNTS
# literal English in presentational positions (title:, label:, hint:,
# placeholder:, subtitle:, detail:, content:) and does NOT count keyed
# strings (get_string(...)), non-string positions, or `#[cfg(test)]`
# blocks. It also asserts the --check ratchet exits nonzero when a
# planted literal pushes a count above baseline, zero at/below.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
SCRIPT="$SCRIPT_DIR/../audit-ui-literals.sh"

UI_REL="core/vauchi-app/src/ui"

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

mk_ui() { # $1 = root, $2 = relative file under ui/, stdin = content
    mkdir -p "$(dirname "$1/$UI_REL/$2")"
    cat > "$1/$UI_REL/$2"
}

# ── 1. Empty workspace → all zero, exit 0 ─────────────────────────────
test_empty_workspace() {
    root=$(mktemp -d)
    out=$("$SCRIPT" "$root"); rc=$?
    assert_eq "empty: exit 0" 0 "$rc"
    assert_eq "empty: titles == 0" "0" "$(extract_counter "$out" ui_literal_titles)"
    assert_eq "empty: labels == 0" "0" "$(extract_counter "$out" ui_literal_labels)"
    assert_eq "empty: total == 0" "0" "$(extract_counter "$out" ui_literal_total)"
    rm -rf "$root"
}

# ── 2. Keyed strings + non-presentational strings → 0 ─────────────────
test_keyed_and_data_score_zero() {
    root=$(mktemp -d)
    mk_ui "$root" clean.rs <<'RS'
fn build(locale: Locale) -> ScreenModel {
    ScreenModel {
        screen_id: "exchange_success".into(),
        title: get_string(locale, "exchange.success_title"),
        components: vec![Component::Text {
            id: "body".into(),
            content: get_string(locale, "exchange.success_body"),
        }],
        actions: vec![ScreenAction {
            id: "done".into(),
            label: get_string(locale, "action.done"),
        }],
    }
}
RS
    out=$("$SCRIPT" "$root"); rc=$?
    assert_eq "keyed: exit 0" 0 "$rc"
    assert_eq "keyed: titles == 0" "0" "$(extract_counter "$out" ui_literal_titles)"
    assert_eq "keyed: labels == 0" "0" "$(extract_counter "$out" ui_literal_labels)"
    rm -rf "$root"
}

# ── 3. Literal English in presentational positions → counted ──────────
test_literals_are_counted() {
    root=$(mktemp -d)
    mk_ui "$root" dirty.rs <<'RS'
fn build() -> ScreenModel {
    ScreenModel {
        title: "Success".into(),
        subtitle: Some("Cards exchanged".into()),
        components: vec![Component::StatusIndicator {
            label: Some("Exchange complete".into()),
            hint: Some("Contact cards have been exchanged".into()),
        }],
        actions: vec![ScreenAction {
            label: "Done".into(),
            placeholder: Some("Type here".into()),
        }],
    }
}
RS
    out=$("$SCRIPT" "$root"); rc=$?
    assert_eq "literals: exit 0 (snapshot mode never gates)" 0 "$rc"
    assert_eq "literals: titles == 1" "1" "$(extract_counter "$out" ui_literal_titles)"
    # subtitle + label + hint + label + placeholder = 5
    assert_eq "literals: labels == 5" "5" "$(extract_counter "$out" ui_literal_labels)"
    assert_eq "literals: total == 6" "6" "$(extract_counter "$out" ui_literal_total)"
    rm -rf "$root"
}

# ── 4. Locale-key literals (contain '.') are NOT counted ───────────────
test_locale_key_literals_excluded() {
    root=$(mktemp -d)
    mk_ui "$root" keyed_literals.rs <<'RS'
fn build() -> ScreenModel {
    ScreenModel {
        title: "exchange.success_title".into(),
        subtitle: Some("exchange.success_subtitle".into()),
        components: vec![Component::StatusIndicator {
            label: Some("exchange.success_label".into()),
            hint: Some("exchange.success_hint".into()),
        }],
        actions: vec![ScreenAction {
            label: "action.done".into(),
            placeholder: Some("form.input_placeholder".into()),
        }],
    }
}
RS
    out=$("$SCRIPT" "$root"); rc=$?
    assert_eq "locale-keys: exit 0" 0 "$rc"
    assert_eq "locale-keys: titles == 0" "0" "$(extract_counter "$out" ui_literal_titles)"
    assert_eq "locale-keys: labels == 0" "0" "$(extract_counter "$out" ui_literal_labels)"
    rm -rf "$root"
}

# ── 5. #[cfg(test)] blocks are NOT counted ─────────────────────────────
test_cfg_test_block_excluded() {
    root=$(mktemp -d)
    mk_ui "$root" tested.rs <<'RS'
fn build() -> ScreenModel {
    ScreenModel { title: "Real".into() }
}
#[cfg(test)]
mod tests {
    #[test]
    fn pins_title() {
        let s = ScreenModel { title: "Test-Only".into(), label: "X".into() };
        assert_eq!(s.title, "Test-Only");
    }
}
RS
    out=$("$SCRIPT" "$root")
    assert_eq "cfg(test): titles == 1 (only production)" "1" "$(extract_counter "$out" ui_literal_titles)"
    assert_eq "cfg(test): labels == 0" "0" "$(extract_counter "$out" ui_literal_labels)"
    rm -rf "$root"
}

# ── 6. --check ratchet: above baseline fails, at/below passes ──────────
test_check_ratchet() {
    root=$(mktemp -d)
    mk_ui "$root" dirty.rs <<'RS'
fn build() -> ScreenModel {
    ScreenModel { title: "One".into(), label: "Two".into() }
}
RS
    baseline="$root/baseline.json"
    "$SCRIPT" "$root" > "$baseline"

    # At baseline → exit 0.
    rc=0; "$SCRIPT" --check "$baseline" "$root" >/dev/null || rc=$?
    assert_eq "check: at baseline exits 0" 0 "$rc"

    # Plant one more literal → above baseline → exit 1.
    mk_ui "$root" more.rs <<'RS'
fn build2() -> ScreenModel {
    ScreenModel { title: "Regression".into() }
}
RS
    rc=0; "$SCRIPT" --check "$baseline" "$root" >/dev/null || rc=$?
    assert_eq "check: above baseline exits 1" 1 "$rc"

    # Remove the planted file → back at baseline → exit 0 (shrink also ok).
    rm "$root/$UI_REL/more.rs" "$root/$UI_REL/dirty.rs"
    rc=0; "$SCRIPT" --check "$baseline" "$root" >/dev/null || rc=$?
    assert_eq "check: below baseline exits 0" 0 "$rc"
    rm -rf "$root"
}

test_empty_workspace
test_keyed_and_data_score_zero
test_literals_are_counted
test_locale_key_literals_excluded
test_cfg_test_block_excluded
test_check_ratchet

printf '\n%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
