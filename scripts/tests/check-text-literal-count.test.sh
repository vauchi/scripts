#!/usr/bin/env bash
# SPDX-FileCopyrightText: 2026 Mattia Egloff <mattia.egloff@pm.me>
#
# SPDX-License-Identifier: GPL-3.0-or-later

# Regression suite for check-text-literal-count.sh.
# Exercises baseline-met / baseline-exceeded / baseline-undershot,
# missing baseline, malformed baseline, multi-path scope, and
# missing-path tolerance.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT="$SCRIPT_DIR/../check-text-literal-count.sh"

pass=0
fail=0

mk_repo() {
    local root="$1"
    mkdir -p "$root/Vauchi/Views" "$root/Vauchi/CoreUI"
}

write_view() {
    local path="$1"
    shift
    mkdir -p "$(dirname "$path")"
    printf '%s\n' "$@" > "$path"
}

assert_exit() {
    local name="$1" want="$2" got="$3"
    if [[ "$want" == "$got" ]]; then
        printf '  PASS %s\n' "$name"
        pass=$((pass + 1))
    else
        printf '  FAIL %s — want exit %s, got %s\n' "$name" "$want" "$got" >&2
        fail=$((fail + 1))
    fi
}

assert_contains() {
    local name="$1" needle="$2" haystack="$3"
    if [[ "$haystack" == *"$needle"* ]]; then
        printf '  PASS %s\n' "$name"
        pass=$((pass + 1))
    else
        printf '  FAIL %s — missing %q\n    haystack: %s\n' "$name" "$needle" "$haystack" >&2
        fail=$((fail + 1))
    fi
}

# ── 1. Count matches baseline → exit 0 ─────────────────────────────
test_count_matches_baseline() {
    local root
    root="$(mktemp -d)"
    trap 'rm -rf "$root"' RETURN
    mk_repo "$root"
    write_view "$root/Vauchi/Views/Foo.swift" \
        'import SwiftUI' \
        'struct Foo: View {' \
        '    var body: some View {' \
        '        VStack {' \
        '            Text("Hello World")' \
        '            Text("Goodbye Friend")' \
        '        }' \
        '    }' \
        '}'
    echo 2 > "$root/.text-literal-baseline"

    set +e
    out="$(bash "$SCRIPT" "$root" Vauchi/Views/ 2>&1)"
    rc=$?
    set -e

    assert_exit "exit 0 when count matches baseline" 0 "$rc"
    assert_contains "OK message present" "matches baseline (2)" "$out"
}

# ── 2. Count below baseline → exit 0 + ratchet hint ─────────────────
test_count_below_baseline() {
    local root
    root="$(mktemp -d)"
    trap 'rm -rf "$root"' RETURN
    mk_repo "$root"
    write_view "$root/Vauchi/Views/Foo.swift" \
        'Text("Only One Literal")'
    echo 5 > "$root/.text-literal-baseline"

    set +e
    out="$(bash "$SCRIPT" "$root" Vauchi/Views/ 2>&1)"
    rc=$?
    set -e

    assert_exit "exit 0 when count below baseline" 0 "$rc"
    assert_contains "ratchet hint" "ratchet baseline down" "$out"
    assert_contains "shows new count" "count 1 (baseline 5)" "$out"
}

# ── 3. Count above baseline → exit 1 + diff hint ────────────────────
test_count_above_baseline() {
    local root
    root="$(mktemp -d)"
    trap 'rm -rf "$root"' RETURN
    mk_repo "$root"
    write_view "$root/Vauchi/Views/Foo.swift" \
        'Text("First Literal")' \
        'Text("Second Literal")' \
        'Text("Third Literal")'
    echo 1 > "$root/.text-literal-baseline"

    set +e
    out="$(bash "$SCRIPT" "$root" Vauchi/Views/ 2>&1)"
    rc=$?
    set -e

    assert_exit "exit 1 when count above baseline" 1 "$rc"
    assert_contains "shows direction" "1 → 3" "$out"
    assert_contains "shows audit grep" "grep -rE" "$out"
}

# ── 4. Lowercase Text(label) and special chars don't count ─────────
test_excludes_non_user_visible() {
    local root
    root="$(mktemp -d)"
    trap 'rm -rf "$root"' RETURN
    mk_repo "$root"
    write_view "$root/Vauchi/Views/Foo.swift" \
        'Text(label)' \
        'Text("+")' \
        'Text("\(count) items")' \
        'Text(viewModel.name)' \
        'Text("Real User Sentence")'
    echo 1 > "$root/.text-literal-baseline"

    set +e
    out="$(bash "$SCRIPT" "$root" Vauchi/Views/ 2>&1)"
    rc=$?
    set -e

    assert_exit "exit 0 — only the real user-sentence counts" 0 "$rc"
}

# ── 5. Missing baseline file → exit 2 with usage hint ──────────────
test_missing_baseline() {
    local root
    root="$(mktemp -d)"
    trap 'rm -rf "$root"' RETURN
    mk_repo "$root"

    set +e
    out="$(bash "$SCRIPT" "$root" Vauchi/Views/ 2>&1)"
    rc=$?
    set -e

    assert_exit "missing baseline exits 2" 2 "$rc"
    assert_contains "missing-baseline hint" "Initialise it with the current count" "$out"
}

# ── 6. Malformed baseline (non-integer) → exit 2 ───────────────────
test_malformed_baseline() {
    local root
    root="$(mktemp -d)"
    trap 'rm -rf "$root"' RETURN
    mk_repo "$root"
    echo "not a number" > "$root/.text-literal-baseline"

    set +e
    out="$(bash "$SCRIPT" "$root" Vauchi/Views/ 2>&1)"
    rc=$?
    set -e

    assert_exit "malformed baseline exits 2" 2 "$rc"
    assert_contains "must contain integer" "must contain a single integer" "$out"
}

# ── 7. Comments and blank lines in baseline are tolerated ──────────
test_baseline_with_comments() {
    local root
    root="$(mktemp -d)"
    trap 'rm -rf "$root"' RETURN
    mk_repo "$root"
    printf '%s\n' \
        '# Hardcoded Text literal cap (Humble UI G3 ratchet).' \
        '# Each retirement MR shrinks this number.' \
        '' \
        '7' \
        > "$root/.text-literal-baseline"
    write_view "$root/Vauchi/Views/Foo.swift" \
        'Text("Hello World")'

    set +e
    out="$(bash "$SCRIPT" "$root" Vauchi/Views/ 2>&1)"
    rc=$?
    set -e

    assert_exit "exit 0 — comments parsed correctly" 0 "$rc"
    assert_contains "uses the integer 7" "baseline 7" "$out"
}

# ── 8. Multi-path scope (macOS-style) covers all configured paths ──
test_multi_path_scope() {
    local root
    root="$(mktemp -d)"
    trap 'rm -rf "$root"' RETURN
    mk_repo "$root"
    write_view "$root/Vauchi/Views/Foo.swift" \
        'Text("View Literal")'
    write_view "$root/Vauchi/CoreUI/Bar.swift" \
        'Text("CoreUI Literal")'
    write_view "$root/Vauchi/VauchiApp.swift" \
        'Text("App Literal")'
    echo 3 > "$root/.text-literal-baseline"

    set +e
    out="$(bash "$SCRIPT" "$root" \
        Vauchi/Views/ Vauchi/CoreUI/ Vauchi/VauchiApp.swift 2>&1)"
    rc=$?
    set -e

    assert_exit "all 3 search paths counted" 0 "$rc"
    assert_contains "count is 3" "matches baseline (3)" "$out"
}

# ── 9. Missing search path is skipped with WARN, not failure ───────
test_missing_path_skipped() {
    local root
    root="$(mktemp -d)"
    trap 'rm -rf "$root"' RETURN
    mk_repo "$root"
    write_view "$root/Vauchi/Views/Foo.swift" \
        'Text("Solo Literal")'
    echo 1 > "$root/.text-literal-baseline"

    set +e
    out="$(bash "$SCRIPT" "$root" \
        Vauchi/Views/ Vauchi/Nonexistent/ 2>&1)"
    rc=$?
    set -e

    assert_exit "missing path is tolerated" 0 "$rc"
    assert_contains "WARN about missing path" "skipping missing path" "$out"
}

# ── 10. All search paths missing → exit 2 ──────────────────────────
test_all_paths_missing() {
    local root
    root="$(mktemp -d)"
    trap 'rm -rf "$root"' RETURN
    mk_repo "$root"
    echo 0 > "$root/.text-literal-baseline"

    set +e
    out="$(bash "$SCRIPT" "$root" \
        NoSuchPath1/ NoSuchPath2/ 2>&1)"
    rc=$?
    set -e

    assert_exit "all paths missing exits 2" 2 "$rc"
    assert_contains "no existing paths error" "no existing search paths" "$out"
}

# ── 11. Repo root not a directory → exit 2 ─────────────────────────
test_invalid_repo_root() {
    set +e
    out="$(bash "$SCRIPT" /nonexistent/path Vauchi/Views/ 2>&1)"
    rc=$?
    set -e

    assert_exit "invalid repo root exits 2" 2 "$rc"
    assert_contains "not a directory" "not a directory" "$out"
}

# ── 12. Count == 0 == baseline → exit 0 (regression: pipefail bug) ──
# Earlier draft used `grep | wc -l` without guarding against grep's
# exit-1-on-no-match under `set -o pipefail`, which made the script
# fail every time the codebase reached its goal state.
test_zero_count_zero_baseline() {
    local root
    root="$(mktemp -d)"
    trap 'rm -rf "$root"' RETURN
    mk_repo "$root"
    write_view "$root/Vauchi/Views/Foo.swift" \
        'import SwiftUI' \
        'struct Foo: View { var body: some View { EmptyView() } }'
    echo 0 > "$root/.text-literal-baseline"

    set +e
    out="$(bash "$SCRIPT" "$root" Vauchi/Views/ 2>&1)"
    rc=$?
    set -e

    assert_exit "exit 0 when count is 0 and baseline is 0" 0 "$rc"
    assert_contains "OK message at zero" "matches baseline (0)" "$out"
}

# ── 13. Usage hint when no args ────────────────────────────────────
test_no_args() {
    set +e
    out="$(bash "$SCRIPT" 2>&1)"
    rc=$?
    set -e

    assert_exit "no args exits 2" 2 "$rc"
    assert_contains "usage line" "Usage:" "$out"
}

# ── Run all ────────────────────────────────────────────────────────

echo "── check-text-literal-count.sh tests ──"
test_count_matches_baseline
test_count_below_baseline
test_count_above_baseline
test_excludes_non_user_visible
test_missing_baseline
test_malformed_baseline
test_baseline_with_comments
test_multi_path_scope
test_missing_path_skipped
test_all_paths_missing
test_invalid_repo_root
test_zero_count_zero_baseline
test_no_args

echo ""
echo "── results: $pass pass, $fail fail ──"
[[ "$fail" == 0 ]]
