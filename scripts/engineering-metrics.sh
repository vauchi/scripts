#!/usr/bin/env bash
# SPDX-FileCopyrightText: 2026 Mattia Egloff <mattia.egloff@pm.me>
#
# SPDX-License-Identifier: GPL-3.0-or-later

# engineering-metrics.sh — Engineering Metrics Dashboard (PI-21)
#
# Aggregates 10 key metrics across all vauchi repos for monthly review.
#
# Usage:
#   engineering-metrics.sh                  # Local metrics only
#   engineering-metrics.sh --gitlab         # Include GitLab CI metrics (requires GITLAB_TOKEN)
#   engineering-metrics.sh --json           # Output as JSON
#   engineering-metrics.sh --gitlab --json  # Full metrics as JSON
#
# Environment variables:
#   GITLAB_TOKEN    — Personal access token with read_api scope (for --gitlab mode)
#   GITLAB_GROUP    — GitLab group path (default: vauchi)
#   VAUCHI_ROOT     — Workspace root (default: auto-detected from script location)
#
# PI-21 Metrics:
#   1. Build time (to unit test results)     — target: < 5 min
#   2. Build success rate                    — target: > 95% green
#   3. Branch coverage                       — target: > 85% overall, > 90% core
#   4. Mutation score                        — target: > 75% critical modules
#   5. Test-to-code ratio                    — target: > 50% core, > 40% clients
#   6. Escaped defect rate                   — target: decreasing trend
#   7. Flaky test rate                       — target: < 2%
#   8. Security finding rate per MR          — target: decreasing trend
#   9. P95 latency trend                     — target: within 10% of baseline
#  10. E2E pass rate                         — target: > 98%

set -euo pipefail

# ─── Configuration ────────────────────────────────────────────────
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
VAUCHI_ROOT="${VAUCHI_ROOT:-$(cd "$SCRIPT_DIR/../.." && pwd)}"
GITLAB_GROUP="${GITLAB_GROUP:-vauchi}"
GITLAB_API="https://gitlab.com/api/v4"
USE_GITLAB=false
OUTPUT_JSON=false
DATE=$(date +%Y-%m-%d)

# Rust repos with test code
CORE_REPOS=("core/vauchi-core" "core/vauchi-protocol" "core/vauchi-mobile")
CLIENT_REPOS=("relay" "cli" "tui" "desktop/src-tauri")
ALL_RUST_REPOS=("${CORE_REPOS[@]}" "${CLIENT_REPOS[@]}")

# GitLab project IDs (slug → path for API)
declare -A GITLAB_PROJECTS=(
    [core]="vauchi/core"
    [relay]="vauchi/relay"
    [cli]="vauchi/cli"
    [tui]="vauchi/tui"
    [desktop]="vauchi/desktop"
    [ios]="vauchi/ios"
    [e2e]="vauchi/e2e"
)

# ─── Argument Parsing ─────────────────────────────────────────────
for arg in "$@"; do
    case "$arg" in
        --gitlab) USE_GITLAB=true ;;
        --json) OUTPUT_JSON=true ;;
        --help|-h)
            sed -n '3,/^$/p' "$0" | sed 's/^# //' | sed 's/^#//'
            exit 0
            ;;
    esac
done

# ─── Helpers ──────────────────────────────────────────────────────

# Print section header (markdown mode)
header() {
    if ! $OUTPUT_JSON; then
        echo ""
        echo "## $1"
        echo ""
    fi
}

# Print metric row: name | value | target | status
metric_row() {
    local name="$1" value="$2" target="$3" status="$4"
    if ! $OUTPUT_JSON; then
        printf "| %-35s | %15s | %20s | %-6s |\n" "$name" "$value" "$target" "$status"
    fi
}

# GitLab API GET request
gitlab_get() {
    local endpoint="$1"
    if [ -z "${GITLAB_TOKEN:-}" ]; then
        echo "null"
        return
    fi
    curl -s --header "PRIVATE-TOKEN: ${GITLAB_TOKEN}" \
        "${GITLAB_API}${endpoint}" 2>/dev/null || echo "null"
}

# URL-encode a string
urlencode() {
    python3 -c "import urllib.parse; print(urllib.parse.quote('$1', safe=''))"
}

# ─── Metric Collection ───────────────────────────────────────────

declare -A METRICS

# --- Metric 5: Test-to-Code Ratio (local) ---
collect_test_ratio() {
    local total_prod=0 total_test=0

    for repo in "${ALL_RUST_REPOS[@]}"; do
        local dir="$VAUCHI_ROOT/$repo"
        [ -d "$dir/src" ] || continue

        local src_dir="$dir/src"
        local test_dir="$dir/tests"

        # Production lines
        local src_lines=0
        if [ -d "$src_dir" ]; then
            src_lines=$(find "$src_dir" -name "*.rs" -exec cat {} + 2>/dev/null | wc -l | tr -d ' ')
        fi

        # External test lines
        local test_lines=0
        if [ -d "$test_dir" ]; then
            test_lines=$(find "$test_dir" -name "*.rs" -exec cat {} + 2>/dev/null | wc -l | tr -d ' ')
        fi

        # Inline test module lines
        local inline_lines=0
        if [ -d "$src_dir" ]; then
            inline_lines=$(find "$src_dir" -name "*.rs" -exec awk '
                /#\[cfg\(test\)\]/ { in_test = 1; depth = 0 }
                in_test {
                    count++
                    n = split($0, c, "")
                    for (i = 1; i <= n; i++) {
                        if (c[i] == "{") depth++
                        if (c[i] == "}") depth--
                    }
                    if (depth == 0 && count > 1) { in_test = 0; count = 0 }
                }
                END { print count + 0 }
            ' {} + 2>/dev/null || echo 0)
        fi

        local prod=$((src_lines - inline_lines))
        local test=$((test_lines + inline_lines))
        total_prod=$((total_prod + prod))
        total_test=$((total_test + test))
    done

    if [ "$total_prod" -gt 0 ]; then
        METRICS[test_ratio]=$(awk "BEGIN { printf \"%.1f\", ($total_test / $total_prod) * 100 }")
        METRICS[test_ratio_prod]=$total_prod
        METRICS[test_ratio_test]=$total_test
    else
        METRICS[test_ratio]="N/A"
    fi
}

# --- Metric 5b: Per-category ratios ---
collect_test_ratio_detail() {
    for category in core client; do
        local total_prod=0 total_test=0
        local repos_ref
        if [ "$category" = "core" ]; then
            repos_ref=("${CORE_REPOS[@]}")
        else
            repos_ref=("${CLIENT_REPOS[@]}")
        fi

        for repo in "${repos_ref[@]}"; do
            local dir="$VAUCHI_ROOT/$repo"
            [ -d "$dir/src" ] || continue

            local src_lines=0 test_lines=0
            src_lines=$(find "$dir/src" -name "*.rs" -exec cat {} + 2>/dev/null | wc -l | tr -d ' ')
            if [ -d "$dir/tests" ]; then
                test_lines=$(find "$dir/tests" -name "*.rs" -exec cat {} + 2>/dev/null | wc -l | tr -d ' ')
            fi
            total_prod=$((total_prod + src_lines))
            total_test=$((total_test + test_lines))
        done

        if [ "$total_prod" -gt 0 ]; then
            METRICS["test_ratio_${category}"]=$(awk "BEGIN { printf \"%.1f\", ($total_test / $total_prod) * 100 }")
        else
            METRICS["test_ratio_${category}"]="N/A"
        fi
    done
}

# --- Test count ---
collect_test_count() {
    local total=0
    for repo in "${ALL_RUST_REPOS[@]}"; do
        local dir="$VAUCHI_ROOT/$repo"
        for search_dir in "$dir/src" "$dir/tests"; do
            [ -d "$search_dir" ] || continue
            local count
            count=$(grep -r '#\[test\]' "$search_dir" --include="*.rs" 2>/dev/null | wc -l | tr -d ' ')
            total=$((total + count))
        done
    done
    METRICS[test_count]=$total
}

# --- Zero-assertion test count ---
collect_zero_assertions() {
    local dirs=()
    for repo in "${ALL_RUST_REPOS[@]}"; do
        local test_dir="$VAUCHI_ROOT/$repo/tests"
        [ -d "$test_dir" ] && dirs+=("$test_dir")
        local src_dir="$VAUCHI_ROOT/$repo/src"
        [ -d "$src_dir" ] && dirs+=("$src_dir")
    done

    if [ ${#dirs[@]} -eq 0 ]; then
        METRICS[zero_assertion_tests]=0
        return
    fi

    local result
    result=$("$SCRIPT_DIR/check-zero-assertions.sh" "${dirs[@]}" 2>/dev/null || true)
    METRICS[zero_assertion_tests]=$(echo "$result" | grep "Zero-assertion tests found:" | awk '{print $NF}')
    METRICS[zero_assertion_tests]=${METRICS[zero_assertion_tests]:-0}
}

# --- Metric 6: Escaped defect rate (count fix: commits in last 30 days) ---
collect_escaped_defects() {
    local total=0
    for project in core relay cli tui desktop e2e; do
        local dir="$VAUCHI_ROOT/$project"
        [ -d "$dir/.git" ] || continue
        local count
        count=$(git -C "$dir" log --oneline --since="30 days ago" --grep="^fix:" --all 2>/dev/null | wc -l | tr -d ' ')
        total=$((total + count))
    done
    METRICS[escaped_defects_30d]=$total
}

# --- Drift score (if drift-detector is available) ---
collect_drift_score() {
    local drift_dir="$VAUCHI_ROOT/drift-detector"
    if [ -d "$drift_dir" ] && [ -f "$drift_dir/dist/index.js" ]; then
        local result
        result=$(cd "$VAUCHI_ROOT" && node "$drift_dir/dist/index.js" audit --ci 2>/dev/null || echo '{}')
        METRICS[drift_total]=$(echo "$result" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('totalDrift', 'N/A'))" 2>/dev/null || echo "N/A")
        METRICS[drift_high]=$(echo "$result" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('highCount', 'N/A'))" 2>/dev/null || echo "N/A")
    else
        METRICS[drift_total]="N/A"
        METRICS[drift_high]="N/A"
    fi
}

# --- GitLab CI Metrics ---
collect_gitlab_metrics() {
    if ! $USE_GITLAB; then
        METRICS[build_time]="N/A (use --gitlab)"
        METRICS[build_success_rate]="N/A (use --gitlab)"
        METRICS[flaky_test_rate]="N/A (use --gitlab)"
        METRICS[security_findings]="N/A (use --gitlab)"
        METRICS[e2e_pass_rate]="N/A (use --gitlab)"
        METRICS[branch_coverage]="N/A (use --gitlab)"
        METRICS[mutation_score]="N/A (use --gitlab)"
        METRICS[p95_latency]="N/A (use --gitlab)"
        return
    fi

    if [ -z "${GITLAB_TOKEN:-}" ]; then
        echo "WARNING: GITLAB_TOKEN not set. GitLab metrics will be unavailable." >&2
        METRICS[build_time]="N/A (no token)"
        METRICS[build_success_rate]="N/A (no token)"
        METRICS[flaky_test_rate]="N/A (no token)"
        METRICS[security_findings]="N/A (no token)"
        METRICS[e2e_pass_rate]="N/A (no token)"
        METRICS[branch_coverage]="N/A (no token)"
        METRICS[mutation_score]="N/A (no token)"
        METRICS[p95_latency]="N/A (no token)"
        return
    fi

    # --- Metric 1: Build time (core repo, last 20 successful pipelines) ---
    local core_id
    core_id=$(urlencode "${GITLAB_PROJECTS[core]}")
    local pipelines
    pipelines=$(gitlab_get "/projects/${core_id}/pipelines?per_page=20&status=success&ref=main")

    if [ "$pipelines" != "null" ] && echo "$pipelines" | python3 -c "import sys,json; json.load(sys.stdin)" 2>/dev/null; then
        local avg_duration
        avg_duration=$(echo "$pipelines" | python3 -c "
import sys, json
data = json.load(sys.stdin)
durations = [p['duration'] for p in data if p.get('duration')]
if durations:
    avg = sum(durations) / len(durations)
    print(f'{avg/60:.1f}')
else:
    print('N/A')
" 2>/dev/null || echo "N/A")
        METRICS[build_time]="${avg_duration} min"
    else
        METRICS[build_time]="N/A"
    fi

    # --- Metric 2: Build success rate (all repos, last 30 days) ---
    local total_pipelines=0 success_pipelines=0
    for project in "${!GITLAB_PROJECTS[@]}"; do
        local pid
        pid=$(urlencode "${GITLAB_PROJECTS[$project]}")
        local all_count
        all_count=$(gitlab_get "/projects/${pid}/pipelines?per_page=100&ref=main&updated_after=$(date -d '30 days ago' +%Y-%m-%dT00:00:00Z 2>/dev/null || date -v-30d +%Y-%m-%dT00:00:00Z 2>/dev/null)" | python3 -c "import sys,json; print(len(json.load(sys.stdin)))" 2>/dev/null || echo 0)
        local ok_count
        ok_count=$(gitlab_get "/projects/${pid}/pipelines?per_page=100&ref=main&status=success&updated_after=$(date -d '30 days ago' +%Y-%m-%dT00:00:00Z 2>/dev/null || date -v-30d +%Y-%m-%dT00:00:00Z 2>/dev/null)" | python3 -c "import sys,json; print(len(json.load(sys.stdin)))" 2>/dev/null || echo 0)
        total_pipelines=$((total_pipelines + all_count))
        success_pipelines=$((success_pipelines + ok_count))
    done

    if [ "$total_pipelines" -gt 0 ]; then
        METRICS[build_success_rate]=$(awk "BEGIN { printf \"%.1f\", ($success_pipelines / $total_pipelines) * 100 }")
    else
        METRICS[build_success_rate]="N/A"
    fi

    # --- Metric 3: Branch coverage (from pipeline coverage value) ---
    local core_coverage
    core_coverage=$(gitlab_get "/projects/${core_id}" | python3 -c "
import sys, json
data = json.load(sys.stdin)
cov = data.get('statistics', {}).get('commit_count')
# GitLab stores coverage at project level from latest pipeline
# Try the project-level coverage field
cov = data.get('coverage')
print(cov if cov else 'N/A')
" 2>/dev/null || echo "N/A")
    METRICS[branch_coverage]="${core_coverage}"

    # --- Metric 4: Mutation score (from latest nightly job artifact) ---
    # Mutation testing results are in CI artifacts — reading them requires
    # downloading artifacts which is complex. Report as manual-check for now.
    METRICS[mutation_score]="check nightly job"

    # --- Metric 7: Flaky test rate ---
    # GitLab doesn't expose this directly. Count retried pipelines as proxy.
    METRICS[flaky_test_rate]="manual check"

    # --- Metric 8: Security findings per MR ---
    METRICS[security_findings]="check SAST reports"

    # --- Metric 9: P95 latency trend ---
    METRICS[p95_latency]="check benchmarks"

    # --- Metric 10: E2E pass rate ---
    local e2e_id
    e2e_id=$(urlencode "${GITLAB_PROJECTS[e2e]}")
    local e2e_total e2e_success
    e2e_total=$(gitlab_get "/projects/${e2e_id}/pipelines?per_page=100&ref=main" | python3 -c "import sys,json; print(len(json.load(sys.stdin)))" 2>/dev/null || echo 0)
    e2e_success=$(gitlab_get "/projects/${e2e_id}/pipelines?per_page=100&ref=main&status=success" | python3 -c "import sys,json; print(len(json.load(sys.stdin)))" 2>/dev/null || echo 0)
    if [ "$e2e_total" -gt 0 ]; then
        METRICS[e2e_pass_rate]=$(awk "BEGIN { printf \"%.1f\", ($e2e_success / $e2e_total) * 100 }")
    else
        METRICS[e2e_pass_rate]="N/A"
    fi
}

# ─── Main ─────────────────────────────────────────────────────────

if ! $OUTPUT_JSON; then
    echo "# Engineering Metrics Dashboard (PI-21)"
    echo ""
    echo "**Date**: ${DATE}"
    echo "**Workspace**: ${VAUCHI_ROOT}"
    echo "**Mode**: $(if $USE_GITLAB; then echo "local + GitLab API"; else echo "local only"; fi)"
fi

# Collect all metrics
collect_test_ratio
collect_test_ratio_detail
collect_test_count
collect_zero_assertions
collect_escaped_defects
collect_drift_score
collect_gitlab_metrics

# ─── Output ───────────────────────────────────────────────────────

if $OUTPUT_JSON; then
    python3 -c "
import json, sys
metrics = {
    'date': '${DATE}',
    'build_time': '${METRICS[build_time]}',
    'build_success_rate': '${METRICS[build_success_rate]}',
    'branch_coverage': '${METRICS[branch_coverage]}',
    'mutation_score': '${METRICS[mutation_score]}',
    'test_ratio_overall': '${METRICS[test_ratio]}',
    'test_ratio_core': '${METRICS[test_ratio_core]}',
    'test_ratio_client': '${METRICS[test_ratio_client]}',
    'test_count': ${METRICS[test_count]},
    'zero_assertion_tests': ${METRICS[zero_assertion_tests]},
    'escaped_defects_30d': ${METRICS[escaped_defects_30d]},
    'flaky_test_rate': '${METRICS[flaky_test_rate]}',
    'security_findings': '${METRICS[security_findings]}',
    'p95_latency': '${METRICS[p95_latency]}',
    'e2e_pass_rate': '${METRICS[e2e_pass_rate]}',
    'drift_total': '${METRICS[drift_total]}',
    'drift_high': '${METRICS[drift_high]}',
    'prod_lines': ${METRICS[test_ratio_prod]:-0},
    'test_lines': ${METRICS[test_ratio_test]:-0},
}
print(json.dumps(metrics, indent=2))
"
    exit 0
fi

# --- Table: PI-21 Core Metrics ---
header "PI-21 Core Metrics"
printf "| %-35s | %15s | %20s | %-6s |\n" "Metric" "Value" "Target" "Status"
printf "|%-37s|%17s|%22s|%-8s|\n" "-------------------------------------" "-----------------" "----------------------" "--------"

# 1. Build time
status="--"
if [[ "${METRICS[build_time]}" =~ ^[0-9] ]]; then
    val=$(echo "${METRICS[build_time]}" | sed 's/ min//')
    if awk "BEGIN { exit !($val <= 5) }"; then status="PASS"; else status="FAIL"; fi
fi
metric_row "Build time (unit test results)" "${METRICS[build_time]}" "< 5 min" "$status"

# 2. Build success rate
status="--"
if [[ "${METRICS[build_success_rate]}" =~ ^[0-9] ]]; then
    if awk "BEGIN { exit !(${METRICS[build_success_rate]} >= 95) }"; then status="PASS"; else status="FAIL"; fi
fi
metric_row "Build success rate (30d)" "${METRICS[build_success_rate]}%" "> 95%" "$status"

# 3. Branch coverage
metric_row "Branch coverage" "${METRICS[branch_coverage]}" "> 85% / > 90% core" "--"

# 4. Mutation score
metric_row "Mutation score (critical)" "${METRICS[mutation_score]}" "> 75%" "--"

# 5. Test-to-code ratio
core_status="--"
if [[ "${METRICS[test_ratio_core]}" =~ ^[0-9] ]]; then
    if awk "BEGIN { exit !(${METRICS[test_ratio_core]} >= 50) }"; then core_status="PASS"; else core_status="FAIL"; fi
fi
client_status="--"
if [[ "${METRICS[test_ratio_client]}" =~ ^[0-9] ]]; then
    if awk "BEGIN { exit !(${METRICS[test_ratio_client]} >= 40) }"; then client_status="PASS"; else client_status="FAIL"; fi
fi
metric_row "Test-to-code ratio (overall)" "${METRICS[test_ratio]}%" "" ""
metric_row "  Core crates" "${METRICS[test_ratio_core]}%" "> 50%" "$core_status"
metric_row "  Client repos" "${METRICS[test_ratio_client]}%" "> 40%" "$client_status"

# 6. Escaped defect rate
metric_row "Escaped defects (fix: commits, 30d)" "${METRICS[escaped_defects_30d]}" "decreasing" "--"

# 7. Flaky test rate
metric_row "Flaky test rate" "${METRICS[flaky_test_rate]}" "< 2%" "--"

# 8. Security findings
metric_row "Security findings per MR" "${METRICS[security_findings]}" "decreasing" "--"

# 9. P95 latency
metric_row "P95 latency trend" "${METRICS[p95_latency]}" "within 10%" "--"

# 10. E2E pass rate
status="--"
if [[ "${METRICS[e2e_pass_rate]}" =~ ^[0-9] ]]; then
    if awk "BEGIN { exit !(${METRICS[e2e_pass_rate]} >= 98) }"; then status="PASS"; else status="FAIL"; fi
fi
metric_row "E2E pass rate" "${METRICS[e2e_pass_rate]}%" "> 98%" "$status"

# --- Table: Local Quality Indicators ---
header "Local Quality Indicators"
printf "| %-35s | %15s |\n" "Indicator" "Value"
printf "|%-37s|%17s|\n" "-------------------------------------" "-----------------"
printf "| %-35s | %15s |\n" "Total #[test] functions" "${METRICS[test_count]}"
printf "| %-35s | %15s |\n" "Zero-assertion tests" "${METRICS[zero_assertion_tests]}"
printf "| %-35s | %15s |\n" "Production code (lines)" "${METRICS[test_ratio_prod]:-N/A}"
printf "| %-35s | %15s |\n" "Test code (lines)" "${METRICS[test_ratio_test]:-N/A}"
printf "| %-35s | %15s |\n" "Drift items (total)" "${METRICS[drift_total]}"
printf "| %-35s | %15s |\n" "Drift items (high severity)" "${METRICS[drift_high]}"

# --- Footer ---
echo ""
echo "---"
echo ""
echo "**Repos scanned**: ${ALL_RUST_REPOS[*]}"
if ! $USE_GITLAB; then
    echo ""
    echo "**Tip**: Run with \`--gitlab\` and \`GITLAB_TOKEN=<token>\` for CI pipeline metrics."
fi
echo ""
echo "_Generated by engineering-metrics.sh (PI-21) on ${DATE}_"
