#!/usr/bin/env bash
# SPDX-FileCopyrightText: 2026 Mattia Egloff <mattia.egloff@pm.me>
#
# SPDX-License-Identifier: GPL-3.0-or-later

# metrics-push.sh — Push engineering metrics to Prometheus Pushgateway
#
# Collects pipeline, test quality, and cycle metrics from
# GitLab API + local workspace, then pushes to the Pushgateway.
# Note: Coverage metrics are pushed by individual CI jobs via push-coverage.sh.
#
# Usage:
#   metrics-push.sh                     # Local: all metrics, push
#   metrics-push.sh --ci                # CI: GitLab API + cycle metrics, push
#   metrics-push.sh --dry-run           # Print Prometheus text to stdout, don't push
#   metrics-push.sh --ci --dry-run      # CI collect to stdout
#
# Environment variables:
#   GITLAB_TOKEN       — Personal access token (local mode)
#   CI_JOB_TOKEN       — Automatic in GitLab CI (CI mode)
#   PUSHGATEWAY_URL    — the push endpoint; PUSHGATEWAY_TOKEN its bearer token
#   VAUCHI_ROOT        — Workspace root (default: auto-detected)
#   PRIVATE_DIR        — Path to _private repo (default: $VAUCHI_ROOT/_private)

set -euo pipefail

# ─── Configuration ────────────────────────────────────────────────
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
VAUCHI_ROOT="${VAUCHI_ROOT:-$(cd "$SCRIPT_DIR/../../.." && pwd)}"
PRIVATE_DIR="${PRIVATE_DIR:-$VAUCHI_ROOT/_private}"
GITLAB_API="https://gitlab.com/api/v4"

# The push itself lives in pushgateway-push.sh
# (sourced from push_metrics()). Override the host/IP/user there if the VPS
# moves — single source of truth across every push site.

CI_MODE=false
DRY_RUN=false
METRICS_TEXT=""

# GitLab project paths (slug → path for API)
declare -A GITLAB_PROJECTS=(
    [core]="vauchi/core"
    [relay]="vauchi/relay"
    [cli]="vauchi/cli"
    [tui]="vauchi/tui"
    [ios]="vauchi/ios"
    [android]="vauchi/android"
    [e2e]="vauchi/e2e"
    [macos]="vauchi/macos"
    [windows]="vauchi/windows"
    [linux-gtk]="vauchi/linux-gtk"
    [linux-qt]="vauchi/linux-qt"
    [ohttp-relay]="vauchi/ohttp-relay"
    [web-demo]="vauchi/web-demo"
    [scripts]="vauchi/scripts"
)

# Repos with Rust test code
CORE_REPOS=("core/vauchi-core" "core/vauchi-protocol" "core/vauchi-platform")
CLIENT_REPOS=("relay" "cli" "tui")
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

# URL-encode a string (pass via env to avoid shell injection)
urlencode() {
    _URLENCODE_INPUT="$1" python3 -c "import urllib.parse, os; print(urllib.parse.quote(os.environ['_URLENCODE_INPUT'], safe=''))"
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

    local http_code body
    body=$(curl -s --header "$token_header" \
        -w "\n%{http_code}" \
        "${GITLAB_API}${endpoint}" 2>/dev/null)
    http_code=$(echo "$body" | tail -1)
    body=$(echo "$body" | sed '$d')

    if [ "$http_code" != "200" ]; then
        echo "WARNING: GitLab API ${endpoint} returned HTTP ${http_code} (auth scope may be too narrow)" >&2
        echo "null"
        return
    fi

    echo "$body"
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

# Push metrics to the Pushgateway via the shared helper.
push_metrics() {
    if $DRY_RUN; then
        echo "$METRICS_TEXT"
        return
    fi

    # shellcheck disable=SC1091  # dynamic source path — not resolvable without -x
    source "$SCRIPT_DIR/pushgateway-push.sh"

    if ! pushgateway_push "$METRICS_TEXT" "/metrics/job/vauchi_engineering"; then
        echo "metrics-push: push failed (non-fatal)" >&2
    fi
}

# 30 days ago in ISO 8601 (Linux + macOS compat)
thirty_days_ago() { # BSD probe first: BSD date misreads -d
    if date -v-1d >/dev/null 2>&1; then
        date -v-30d +%Y-%m-%dT00:00:00Z
    else
        date -d '30 days ago' +%Y-%m-%dT00:00:00Z 2>/dev/null || echo "1970-01-01T00:00:00Z" # portable-shell-ok: GNU branch of a probed switch
    fi
}

# Days between a YYYY-MM-DD date and today
days_since() {
    local then_epoch now_epoch
    if date -v-1d >/dev/null 2>&1; then
        then_epoch=$(date -jf "%Y-%m-%d" "$1" +%s 2>/dev/null || echo 0)
    else
        then_epoch=$(date -d "$1" +%s 2>/dev/null || echo 0) # portable-shell-ok: GNU branch of a probed BSD/GNU switch
    fi
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

        # 30-day success ratio — single API call to avoid race condition
        local all_json counts all_count ok_count
        all_json=$(gitlab_get "/projects/${pid}/pipelines?per_page=100&ref=main&updated_after=${since}")
        counts=$(echo "$all_json" | python3 -c "
import sys, json
data = json.load(sys.stdin)
total = len(data)
ok = sum(1 for p in data if p.get('status') == 'success')
print(f'{total} {ok}')
" 2>/dev/null || echo "0 0")
        read -r all_count ok_count <<< "$counts"

        if [ "$all_count" -gt 0 ] 2>/dev/null; then
            local ratio
            ratio=$(awk "BEGIN { printf \"%.4f\", $ok_count / $all_count }")
            append_metric "vauchi_eng_pipeline_success_ratio" "repo=\"${repo}\"" "$ratio"
        fi
    done
}

# Pipeline health — median, P95, pass rate (main + MR), top flaky jobs
# Complements collect_pipeline_metrics() which emits avg + 30-day ratio.
# Uses last 20 pipelines per ref (main / MR) for responsiveness to recent regressions.
# New gauge names are prefixed vauchi_eng_ci_ to distinguish from
# the existing vauchi_eng_pipeline_* series.
collect_ci_health_metrics() {
    for repo in "${!GITLAB_PROJECTS[@]}"; do
        local pid
        pid=$(urlencode "${GITLAB_PROJECTS[$repo]}")

        # ── Main branch: last 20 pipelines, success-only for duration ──
        # GitLab's list endpoint returns `duration: null` on recent pipelines;
        # fall back to (updated_at − created_at) like collect_pipeline_metrics.
        local main_json main_out
        main_json=$(gitlab_get "/projects/${pid}/pipelines?per_page=20&ref=main")
        if [ "$main_json" != "null" ]; then
            main_out=$(echo "$main_json" | python3 -c "
import sys, json, statistics
from datetime import datetime
def dur(p):
    d = p.get('duration')
    if d: return float(d)
    c, u = p.get('created_at'), p.get('updated_at')
    if c and u:
        t0 = datetime.fromisoformat(c.replace('Z', '+00:00'))
        t1 = datetime.fromisoformat(u.replace('Z', '+00:00'))
        return max(0, (t1 - t0).total_seconds())
    return 0
data = json.load(sys.stdin)
durs = [dur(p) for p in data if p.get('status') == 'success']
durs = [d for d in durs if d > 0]
total = len(data)
ok = sum(1 for p in data if p.get('status') == 'success')
if durs:
    med = statistics.median(durs)
    s = sorted(durs)
    # P95 index for small-N: ceil(0.95 * N) - 1
    idx = max(0, int(-(-95 * len(s) // 100)) - 1)
    p95 = s[idx]
else:
    med = p95 = 0
ratio = (ok / total) if total else 0
print(f'{med:.0f} {p95:.0f} {ratio:.4f} {total}')
" 2>/dev/null || echo "0 0 0 0")
            local med_s p95_s ratio_s n_s
            read -r med_s p95_s ratio_s n_s <<< "$main_out"
            if [ "$n_s" -gt 0 ] 2>/dev/null; then
                append_metric "vauchi_eng_ci_main_median_seconds" "repo=\"${repo}\"" "$med_s"
                append_metric "vauchi_eng_ci_main_p95_seconds"    "repo=\"${repo}\"" "$p95_s"
                append_metric "vauchi_eng_ci_main_pass_ratio"     "repo=\"${repo}\"" "$ratio_s"
            fi
        fi

        # ── MR pipelines: last 20, pass rate + top flaky jobs ──
        local mr_json mr_out
        mr_json=$(gitlab_get "/projects/${pid}/pipelines?per_page=20&source=merge_request_event")
        if [ "$mr_json" != "null" ]; then
            mr_out=$(echo "$mr_json" | python3 -c "
import sys, json, statistics
from datetime import datetime
def dur(p):
    d = p.get('duration')
    if d: return float(d)
    c, u = p.get('created_at'), p.get('updated_at')
    if c and u:
        t0 = datetime.fromisoformat(c.replace('Z', '+00:00'))
        t1 = datetime.fromisoformat(u.replace('Z', '+00:00'))
        return max(0, (t1 - t0).total_seconds())
    return 0
data = json.load(sys.stdin)
durs = [dur(p) for p in data if p.get('status') == 'success']
durs = [d for d in durs if d > 0]
total = len(data)
ok = sum(1 for p in data if p.get('status') == 'success')
med = statistics.median(durs) if durs else 0
ratio = (ok / total) if total else 0
print(f'{med:.0f} {ratio:.4f} {total}')
" 2>/dev/null || echo "0 0 0")
            local med_m ratio_m n_m
            read -r med_m ratio_m n_m <<< "$mr_out"
            if [ "$n_m" -gt 0 ] 2>/dev/null; then
                append_metric "vauchi_eng_ci_mr_median_seconds" "repo=\"${repo}\"" "$med_m"
                append_metric "vauchi_eng_ci_mr_pass_ratio"     "repo=\"${repo}\"" "$ratio_m"
            fi

            # Top-N flakiest job names over last 20 MR pipelines.
            # One fetch per pipeline; bounded to 20 × ~1 req = small API cost.
            local flaky_out
            flaky_out=$(echo "$mr_json" | python3 -c "
import sys, json
d = json.load(sys.stdin)
ids = [p.get('id') for p in d if p.get('id')]
print(' '.join(str(x) for x in ids))
" 2>/dev/null || echo "")
            if [ -n "$flaky_out" ]; then
                local _acc=""
                for pipeline_id in $flaky_out; do
                    local jobs_json
                    jobs_json=$(gitlab_get "/projects/${pid}/pipelines/${pipeline_id}/jobs?per_page=100")
                    if [ "$jobs_json" != "null" ]; then
                        _acc+=$(echo "$jobs_json" | python3 -c "
import sys, json
d = json.load(sys.stdin)
for j in d:
    if j.get('status') == 'failed' and not j.get('allow_failure'):
        print(j.get('name'))
" 2>/dev/null || true)
                        _acc+=$'\n'
                    fi
                done
                # Count failures per job and emit top 5.
                # Process substitution keeps append_metric in the current shell
                # (pipe `| while` would lose METRICS_TEXT updates in a subshell).
                while read -r count job; do
                    [ -z "$job" ] && continue
                    # ci_job, not job: the Pushgateway overwrites a pushed
                    # `job` label with the grouping key's, which made every
                    # series of a repository identical and the payload
                    # invalid (private#470).
                    append_metric "vauchi_eng_ci_mr_job_failures_20" \
                        "repo=\"${repo}\",ci_job=\"${job}\"" "$count"
                done < <(echo "$_acc" | grep -v '^$' | sort | uniq -c | sort -rn | head -5)
            fi
        fi
    done
}

# E2E pipeline pass rate (GitLab API)
collect_e2e_metrics() {
    local since pid
    since=$(thirty_days_ago)
    pid=$(urlencode "${GITLAB_PROJECTS[e2e]}")

    # Single API call to avoid race condition between total and success counts
    local all_json counts total success
    all_json=$(gitlab_get "/projects/${pid}/pipelines?per_page=100&ref=main&updated_after=${since}")
    counts=$(echo "$all_json" | python3 -c "
import sys, json
data = json.load(sys.stdin)
total = len(data)
ok = sum(1 for p in data if p.get('status') == 'success')
print(f'{total} {ok}')
" 2>/dev/null || echo "0 0")
    read -r total success <<< "$counts"

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
            count=$(find "$search_dir" -name '*.rs' -exec grep -h '#\[test\]' {} + 2>/dev/null | wc -l | tr -d ' ')
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
    for project in core relay cli tui ios android e2e; do
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
        pending=$(grep -cE '^[[:space:]]*(-|[0-9]+\.)[[:space:]]*\[ \]' "$plan_file" 2>/dev/null || echo "0")
        completed=$(grep -cE '^[[:space:]]*(-|[0-9]+\.)[[:space:]]*\[x\]' "$plan_file" 2>/dev/null || echo "0")
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

echo "  Collecting CI health metrics (median/P95/MR pass/job flakes)..." >&2
collect_ci_health_metrics

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

# Sanity check: the script queries every repo in GITLAB_PROJECTS. If only a
# handful returned data, the CI token likely lacks cross-project API access.
# (With a job token: vauchi/scripts missing from a target project's job-token
# allowlist. On the production host, which runs this from vauchi-metrics.timer
# with a read-only token, a token without access to those projects.)
repos_with_data=$(echo "$METRICS_TEXT" | grep -oE 'repo="[^"]+"' | sed 's/repo="//;s/"$//' | sort -u | wc -l | tr -d ' ')
expected_repos=${#GITLAB_PROJECTS[@]}
if [ "$repos_with_data" -lt "$(( expected_repos / 2 ))" ]; then
    echo "WARNING: Only ${repos_with_data}/${expected_repos} repos returned data." >&2
    echo "WARNING: Check CI_JOB_TOKEN allowlists — vauchi/scripts must be allowed to read each target project." >&2
fi

# The payload says when it was built. It shares its Pushgateway group with
# _private's cycle metrics, so the group's push_time_seconds stayed fresh
# while this payload was rejected for months; EngineeringMetricsStale reads
# this line instead (private#470).
append_metric "vauchi_eng_daily_push_timestamp_seconds" "" "$(date +%s)"

push_metrics

echo "vauchi metrics-push: done ($(echo "$METRICS_TEXT" | wc -l | tr -d ' ') metric lines, ${repos_with_data}/${expected_repos} repos)" >&2
