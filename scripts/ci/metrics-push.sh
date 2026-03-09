#!/usr/bin/env bash
# SPDX-FileCopyrightText: 2026 Mattia Egloff <mattia.egloff@pm.me>
#
# SPDX-License-Identifier: GPL-3.0-or-later

# metrics-push.sh — Push engineering metrics to Prometheus Pushgateway
#
# Collects pipeline, test quality, and cycle metrics from
# GitLab API + local workspace, then pushes to Prometheus via SSH.
# Note: Coverage metrics are pushed by individual CI jobs via push-coverage.sh.
#
# Usage:
#   metrics-push.sh                     # Local: all metrics, push via SSH
#   metrics-push.sh --ci                # CI: GitLab API + cycle metrics, push via SSH
#   metrics-push.sh --dry-run           # Print Prometheus text to stdout, don't push
#   metrics-push.sh --ci --dry-run      # CI collect to stdout
#
# Environment variables:
#   GITLAB_TOKEN       — Personal access token (local mode)
#   CI_JOB_TOKEN       — Automatic in GitLab CI (CI mode)
#   PUSHGATEWAY_URL    — Override push target (default: SSH to VPS localhost:9091)
#   VAUCHI_ROOT        — Workspace root (default: auto-detected)
#   PRIVATE_DIR        — Path to _private repo (default: $VAUCHI_ROOT/_private)

set -euo pipefail

# ─── Configuration ────────────────────────────────────────────────
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
VAUCHI_ROOT="${VAUCHI_ROOT:-$(cd "$SCRIPT_DIR/../../.." && pwd)}"
PRIVATE_DIR="${PRIVATE_DIR:-$VAUCHI_ROOT/_private}"
GITLAB_API="https://gitlab.com/api/v4"

CI_MODE=false
DRY_RUN=false
METRICS_TEXT=""

# GitLab project paths (slug → path for API)
declare -A GITLAB_PROJECTS=(
    [core]="vauchi/core"
    [relay]="vauchi/relay"
    [cli]="vauchi/cli"
    [tui]="vauchi/tui"
    [desktop]="vauchi/desktop"
    [ios]="vauchi/ios"
    [android]="vauchi/android"
    [e2e]="vauchi/e2e"
)

# Repos with Rust test code
CORE_REPOS=("core/vauchi-core" "core/vauchi-protocol" "core/vauchi-platform")
CLIENT_REPOS=("relay" "cli" "tui" "desktop/src-tauri")
ALL_RUST_REPOS=("${CORE_REPOS[@]}" "${CLIENT_REPOS[@]}")

# ─── Argument Parsing ────────────────────────────────────────────
for arg in "$@"; do
    case "$arg" in
        --ci) CI_MODE=true ;;
        --dry-run) DRY_RUN=true ;;
        --help|-h)
            sed -n '6,/^$/p' "$0" | sed 's/^# //' | sed 's/^#//'
            exit 0
            ;;
    esac
done

# ─── Helpers ─────────────────────────────────────────────────────

# URL-encode a string
urlencode() {
    python3 -c "import urllib.parse; print(urllib.parse.quote('$1', safe=''))"
}

# GitLab API GET request (uses CI_JOB_TOKEN in CI, GITLAB_TOKEN locally)
gitlab_get() {
    local endpoint="$1"
    local token_header

    if [ -n "${CI_JOB_TOKEN:-}" ]; then
        token_header="JOB-TOKEN: ${CI_JOB_TOKEN}"
    elif [ -n "${GITLAB_TOKEN:-}" ]; then
        token_header="PRIVATE-TOKEN: ${GITLAB_TOKEN}"
    else
        echo "null"
        return
    fi

    curl -s --header "$token_header" \
        "${GITLAB_API}${endpoint}" 2>/dev/null || echo "null"
}

# Append a metric line in Prometheus exposition format
append_metric() {
    local name="$1" labels="$2" value="$3"
    if [ -n "$labels" ]; then
        METRICS_TEXT+="${name}{${labels}} ${value}"$'\n'
    else
        METRICS_TEXT+="${name} ${value}"$'\n'
    fi
}

# Push metrics to pushgateway
push_metrics() {
    if $DRY_RUN; then
        echo "$METRICS_TEXT"
        return
    fi

    if [ -n "${PUSHGATEWAY_URL:-}" ]; then
        echo "$METRICS_TEXT" | curl -s --data-binary @- \
            "${PUSHGATEWAY_URL}/metrics/job/vauchi_engineering"
    else
        echo "$METRICS_TEXT" | ssh vauchi@bold-hopper-vps \
            "curl -s --data-binary @- http://localhost:9091/metrics/job/vauchi_engineering"
    fi
}

# 30 days ago in ISO 8601 (Linux + macOS compat)
thirty_days_ago() {
    date -d '30 days ago' +%Y-%m-%dT00:00:00Z 2>/dev/null \
        || date -v-30d +%Y-%m-%dT00:00:00Z 2>/dev/null \
        || echo "1970-01-01T00:00:00Z"
}

# Days between a YYYY-MM-DD date and today
days_since() {
    local then_epoch now_epoch
    then_epoch=$(date -d "$1" +%s 2>/dev/null || date -jf "%Y-%m-%d" "$1" +%s 2>/dev/null || echo 0)
    now_epoch=$(date +%s)
    echo $(( (now_epoch - then_epoch) / 86400 ))
}

# ─── Collectors ──────────────────────────────────────────────────

# Pipeline duration and success rate per repo (GitLab API)
collect_pipeline_metrics() {
    local since
    since=$(thirty_days_ago)

    for repo in "${!GITLAB_PROJECTS[@]}"; do
        local pid
        pid=$(urlencode "${GITLAB_PROJECTS[$repo]}")

        # Average wall-clock time of last 20 successful pipelines on main
        local pipelines
        pipelines=$(gitlab_get "/projects/${pid}/pipelines?per_page=20&status=success&ref=main")

        if [ "$pipelines" != "null" ]; then
            local avg_secs
            avg_secs=$(echo "$pipelines" | python3 -c "
import sys, json
from datetime import datetime
data = json.load(sys.stdin)
durations = []
for p in data:
    c = p.get('created_at', '')
    u = p.get('updated_at', '')
    if c and u:
        t0 = datetime.fromisoformat(c.replace('Z', '+00:00'))
        t1 = datetime.fromisoformat(u.replace('Z', '+00:00'))
        durations.append((t1 - t0).total_seconds())
print(f'{sum(durations)/len(durations):.0f}' if durations else '0')
" 2>/dev/null || echo "0")
            append_metric "vauchi_eng_pipeline_duration_seconds" "repo=\"${repo}\"" "$avg_secs"
        fi

        # 30-day success ratio
        local all_count ok_count
        all_count=$(gitlab_get "/projects/${pid}/pipelines?per_page=100&ref=main&updated_after=${since}" \
            | python3 -c "import sys,json; print(len(json.load(sys.stdin)))" 2>/dev/null || echo "0")
        ok_count=$(gitlab_get "/projects/${pid}/pipelines?per_page=100&ref=main&status=success&updated_after=${since}" \
            | python3 -c "import sys,json; print(len(json.load(sys.stdin)))" 2>/dev/null || echo "0")

        if [ "$all_count" -gt 0 ] 2>/dev/null; then
            local ratio
            ratio=$(awk "BEGIN { printf \"%.4f\", $ok_count / $all_count }")
            append_metric "vauchi_eng_pipeline_success_ratio" "repo=\"${repo}\"" "$ratio"
        fi
    done
}

# E2E pipeline pass rate (GitLab API)
collect_e2e_metrics() {
    local since pid
    since=$(thirty_days_ago)
    pid=$(urlencode "${GITLAB_PROJECTS[e2e]}")

    local total success
    total=$(gitlab_get "/projects/${pid}/pipelines?per_page=100&ref=main&updated_after=${since}" \
        | python3 -c "import sys,json; print(len(json.load(sys.stdin)))" 2>/dev/null || echo "0")
    success=$(gitlab_get "/projects/${pid}/pipelines?per_page=100&ref=main&status=success&updated_after=${since}" \
        | python3 -c "import sys,json; print(len(json.load(sys.stdin)))" 2>/dev/null || echo "0")

    if [ "$total" -gt 0 ] 2>/dev/null; then
        local ratio
        ratio=$(awk "BEGIN { printf \"%.4f\", $success / $total }")
        append_metric "vauchi_eng_e2e_pass_ratio" "" "$ratio"
    fi
}

# Test count, ratio, zero-assertion violations, escaped defects (local only)
collect_test_metrics() {
    # Test count
    local total_tests=0
    for repo in "${ALL_RUST_REPOS[@]}"; do
        local dir="$VAUCHI_ROOT/$repo"
        for search_dir in "$dir/src" "$dir/tests"; do
            [ -d "$search_dir" ] || continue
            local count
            count=$(grep -r '#\[test\]' "$search_dir" --include="*.rs" 2>/dev/null | wc -l | tr -d ' ')
            total_tests=$((total_tests + count))
        done
    done
    append_metric "vauchi_eng_test_count" "" "$total_tests"

    # Test-to-code ratio per category
    for category in core client overall; do
        local total_prod=0 total_test=0
        local repos_ref=()

        case "$category" in
            core) repos_ref=("${CORE_REPOS[@]}") ;;
            client) repos_ref=("${CLIENT_REPOS[@]}") ;;
            overall) repos_ref=("${ALL_RUST_REPOS[@]}") ;;
        esac

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
            local ratio
            ratio=$(awk "BEGIN { printf \"%.4f\", $total_test / $total_prod }")
            append_metric "vauchi_eng_test_ratio" "category=\"${category}\"" "$ratio"
        fi
    done

    # Zero-assertion tests (CC-03 violations)
    local zero_count=0
    local dirs=()
    for repo in "${ALL_RUST_REPOS[@]}"; do
        local test_dir="$VAUCHI_ROOT/$repo/tests"
        [ -d "$test_dir" ] && dirs+=("$test_dir")
        local src_dir="$VAUCHI_ROOT/$repo/src"
        [ -d "$src_dir" ] && dirs+=("$src_dir")
    done

    if [ ${#dirs[@]} -gt 0 ]; then
        local result
        result=$("$SCRIPT_DIR/../check-zero-assertions.sh" "${dirs[@]}" 2>/dev/null || true)
        zero_count=$(echo "$result" | grep "Zero-assertion tests found:" | awk '{print $NF}')
        zero_count=${zero_count:-0}
    fi
    append_metric "vauchi_eng_zero_assertion_tests" "" "$zero_count"

    # Escaped defects (fix: commits in 30 days)
    local escaped=0
    for project in core relay cli tui desktop ios android e2e; do
        local dir="$VAUCHI_ROOT/$project"
        [ -d "$dir/.git" ] || continue
        local count
        count=$(git -C "$dir" log --oneline --since="30 days ago" --grep="^fix:" --all 2>/dev/null | wc -l | tr -d ' ')
        escaped=$((escaped + count))
    done
    append_metric "vauchi_eng_escaped_defects" "" "$escaped"
}

# Problem record cycle metrics (parsed from _private)
collect_cycle_metrics() {
    [ -d "$PRIVATE_DIR/docs/problems" ] || return 0

    local -A status_counts
    local -A oldest_days
    local stale_count=0

    # Scan problem records
    for dir in "$PRIVATE_DIR"/docs/problems/*/; do
        [ -d "$dir" ] || continue
        local readme="$dir/README.md"
        [ -f "$readme" ] || continue

        # Skip done/ subdirectory
        [[ "$dir" == *"/done/"* ]] && continue

        # Extract status from markdown table: | **Status**  | `implementing` |
        local status
        # shellcheck disable=SC2016
        status=$(sed -n 's/.*\*\*Status\*\*.*`\([^`]*\)`.*/\1/p' "$readme" 2>/dev/null | head -1)
        status=${status:-unknown}

        # Count per status
        status_counts[$status]=$(( ${status_counts[$status]:-0} + 1 ))

        # Extract created date from dir name: 2026-02-03-slug → 2026-02-03
        local created
        created=$(basename "$dir" | grep -oE '^[0-9]{4}-[0-9]{2}-[0-9]{2}' || echo "")
        if [ -n "$created" ]; then
            local age
            age=$(days_since "$created")

            # Track oldest per status
            if [ "${oldest_days[$status]:-0}" -lt "$age" ]; then
                oldest_days[$status]=$age
            fi

            # Staleness check (from CLAUDE.md rules)
            case "$status" in
                intake)
                    [ "$age" -gt 14 ] && stale_count=$((stale_count + 1))
                    ;;
                investigating|planning|implementing|testing)
                    [ "$age" -gt 30 ] && stale_count=$((stale_count + 1))
                    ;;
            esac
        fi
    done

    # Emit status counts
    for status in "${!status_counts[@]}"; do
        append_metric "vauchi_eng_problems_by_status" "status=\"${status}\"" "${status_counts[$status]}"
    done

    # Emit oldest age per status
    for status in "${!oldest_days[@]}"; do
        append_metric "vauchi_eng_problem_oldest_days" "status=\"${status}\"" "${oldest_days[$status]}"
    done

    append_metric "vauchi_eng_stale_problems" "" "$stale_count"

    # Plan task counts
    local total_pending=0 total_completed=0

    # Collect plan files from problem records and planning/todo
    local plan_files=()
    while IFS= read -r f; do
        [ -n "$f" ] && plan_files+=("$f")
    done < <(find "$PRIVATE_DIR/docs/problems" \( -name "plan.md" -o -name "*.plan.md" \) 2>/dev/null)
    while IFS= read -r f; do
        [ -n "$f" ] && plan_files+=("$f")
    done < <(find "$PRIVATE_DIR/docs/planning/todo" -name "*.plan.md" 2>/dev/null)

    for plan_file in "${plan_files[@]}"; do
        [ -f "$plan_file" ] || continue
        local pending completed
        # Match both "- [ ]" and "1. [ ]" style checkboxes
        pending=$(grep -cE '^\s*(-|[0-9]+\.)\s*\[ \]' "$plan_file" 2>/dev/null || echo "0")
        completed=$(grep -cE '^\s*(-|[0-9]+\.)\s*\[x\]' "$plan_file" 2>/dev/null || echo "0")
        pending=${pending//[^0-9]/}; pending=${pending:-0}
        completed=${completed//[^0-9]/}; completed=${completed:-0}
        total_pending=$((total_pending + pending))
        total_completed=$((total_completed + completed))
    done

    append_metric "vauchi_eng_plan_tasks" "state=\"pending\"" "$total_pending"
    append_metric "vauchi_eng_plan_tasks" "state=\"completed\"" "$total_completed"

    local total=$((total_pending + total_completed))
    if [ "$total" -gt 0 ]; then
        local ratio
        ratio=$(awk "BEGIN { printf \"%.4f\", $total_completed / $total }")
        append_metric "vauchi_eng_plan_completion_ratio" "" "$ratio"
    fi
}

# Open branches and oldest branch age per repo (GitLab API)
collect_branch_metrics() {
    for repo in "${!GITLAB_PROJECTS[@]}"; do
        local pid
        pid=$(urlencode "${GITLAB_PROJECTS[$repo]}")

        local branches_json
        branches_json=$(gitlab_get "/projects/${pid}/repository/branches?per_page=100")

        if [ "$branches_json" != "null" ]; then
            local result
            result=$(echo "$branches_json" | python3 -c "
import sys, json
from datetime import datetime, timezone
data = json.load(sys.stdin)
non_main = [b for b in data if b['name'] != 'main' and not b.get('merged', False)]
print(len(non_main))
if non_main:
    oldest = min(
        datetime.fromisoformat(b['commit']['committed_date'].replace('Z', '+00:00'))
        for b in non_main
    )
    age = (datetime.now(timezone.utc) - oldest).days
    print(age)
else:
    print(0)
" 2>/dev/null || echo -e "0\n0")

            local count age
            count=$(echo "$result" | head -1)
            age=$(echo "$result" | tail -1)

            append_metric "vauchi_eng_open_branches" "repo=\"${repo}\"" "$count"
            append_metric "vauchi_eng_oldest_branch_days" "repo=\"${repo}\"" "$age"
        fi
    done
}

# ─── Main ────────────────────────────────────────────────────────

echo "vauchi metrics-push: collecting metrics (ci=${CI_MODE}, dry-run=${DRY_RUN})" >&2

# In CI mode, skip _private clone — cycle metrics are pushed by _private's own
# metrics:cycle job on merge to main. Local runs still collect if _private exists.
if $CI_MODE; then
    echo "  Skipping _private clone (cycle metrics pushed by _private CI)" >&2
fi

# Run collectors
echo "  Collecting pipeline metrics..." >&2
collect_pipeline_metrics

echo "  Collecting e2e metrics..." >&2
collect_e2e_metrics

if ! $CI_MODE; then
    echo "  Collecting test metrics (local)..." >&2
    collect_test_metrics
fi

if ! $CI_MODE; then
    echo "  Collecting cycle metrics..." >&2
    collect_cycle_metrics
else
    echo "  Skipping cycle metrics (handled by _private CI)..." >&2
fi

echo "  Collecting branch metrics..." >&2
collect_branch_metrics

# Push or print
if [ -z "$METRICS_TEXT" ]; then
    echo "WARNING: No metrics collected" >&2
    exit 0
fi

push_metrics

echo "vauchi metrics-push: done ($(echo "$METRICS_TEXT" | wc -l | tr -d ' ') metric lines)" >&2
