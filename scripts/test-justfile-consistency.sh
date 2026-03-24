#!/usr/bin/env bash
# SPDX-FileCopyrightText: 2026 Mattia Egloff <mattia.egloff@pm.me>
# SPDX-License-Identifier: GPL-3.0-or-later

# test-justfile-consistency.sh — Verify justfile variables are used consistently.
#
# Run: bash scripts/scripts/test-justfile-consistency.sh
# Fails if hardcoded values exist where variables should be used.

set -uo pipefail

PASS=0
FAIL=0

assert_variable_defined() {
    local label="$1" var_name="$2" file="$3"
    if grep -q "^${var_name} :=" "$file" 2>/dev/null; then
        echo "  PASS: $label"
        PASS=$(( PASS + 1 ))
    else
        echo "  FAIL: $label — variable '$var_name' not defined in $file"
        FAIL=$(( FAIL + 1 ))
    fi
}

echo "=== Consistency: iOS simulator name ==="

# The simulator name should only appear in the variable definition
assert_variable_defined "ios_simulator defined in justfile" "ios_simulator" "justfile"

# No hardcoded simulator names in recipe files (excluding the definition)
JUST_FILES=(just/apps.just just/mobile.just just/e2e.just justfile)
for f in "${JUST_FILES[@]}"; do
    # Check for any hardcoded iPhone simulator names (iPhone NN Pro pattern)
    # that are NOT inside a {{ variable }} interpolation
    matches=$(grep -n 'iPhone 1[0-9] Pro' "$f" 2>/dev/null \
        | grep -v ':=' \
        | grep -v '{{ ios_simulator }}' \
        | grep -v 'Hint:' \
        || true)
    if [[ -z "$matches" ]]; then
        echo "  PASS: no hardcoded simulator in $f"
        PASS=$(( PASS + 1 ))
    else
        echo "  FAIL: hardcoded simulator name in $f:"
        printf '    %s\n' "$matches"
        FAIL=$(( FAIL + 1 ))
    fi
done

echo ""
echo "=== Consistency: metrics repo lists ==="

assert_variable_defined "metrics_coverage_repos defined" "metrics_coverage_repos" "just/gitlab.just"
assert_variable_defined "metrics_all_repos defined" "metrics_all_repos" "just/gitlab.just"

# No hardcoded repo iteration in gitlab.just metrics recipes
matches=$(grep -n 'for repo in core cli' just/gitlab.just 2>/dev/null || true)
if [[ -z "$matches" ]]; then
    echo "  PASS: no hardcoded 'for repo in core cli' in gitlab.just"
    PASS=$(( PASS + 1 ))
else
    echo "  FAIL: hardcoded repo list in gitlab.just:"
    printf '    %s\n' "$matches"
    FAIL=$(( FAIL + 1 ))
fi

echo ""
echo "══════════════════════════════════════"
echo "Results: $PASS passed, $FAIL failed"
echo "══════════════════════════════════════"
if [[ $FAIL -gt 0 ]]; then
    exit 1
else
    exit 0
fi
