#!/usr/bin/env bash
# SPDX-FileCopyrightText: 2026 Mattia Egloff <mattia.egloff@pm.me>
#
# SPDX-License-Identifier: GPL-3.0-or-later
#
# Risk dashboard — surfaces actionable risk signals from plans, problems,
# and git history. Focuses on blockers, stalled progress, and recurring
# failure patterns rather than subjective risk scoring.
#
# Usage: ./risk-dashboard.sh [--json]
#   --json  Output machine-readable JSON instead of formatted text

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WORKSPACE_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

# shellcheck source=output-helpers.sh
source "$SCRIPT_DIR/output-helpers.sh"

JSON_MODE=false
[[ "${1:-}" == "--json" ]] && JSON_MODE=true

PROBLEMS_DIR="$WORKSPACE_ROOT/_private/docs/problems"
PLANNING_DIR="$WORKSPACE_ROOT/_private/docs/planning"
POSTMORTEMS_DIR="$PLANNING_DIR/post-mortems"
TODO_DIR="$PLANNING_DIR/todo"

NOW=$(date +%s)
ISSUES=0
WARNINGS=0

# ── 1. Blocked items in active plans ──────────────────────────────
find_blocked_items() {
    header "Blocked Items"
    local count=0

    while IFS= read -r line; do
        local file="${line%%:*}"
        local match="${line#*:}"
        local relpath="${file#"$WORKSPACE_ROOT"/}"
        if $JSON_MODE; then
            echo "{\"type\":\"blocked\",\"file\":\"$relpath\",\"match\":\"$match\"}"
        else
            status_fail "$relpath" "$match"
        fi
        count=$((count + 1))
    done < <(grep -rn -i "BLOCKED\|blocked on\|blocked by" "$TODO_DIR" 2>/dev/null | grep -v "^Binary" || true)

    if [[ $count -eq 0 ]]; then
        $JSON_MODE || status_ok "No blocked items" ""
    else
        ISSUES=$((ISSUES + count))
        $JSON_MODE || echo ""
        $JSON_MODE || status_info "Total blocked" "$count items across active plans"
    fi
    echo ""
}

# ── 2. Stalled plans (high % but no git activity in 7+ days) ─────
find_stalled_plans() {
    header "Stalled Progress (>7 days without commits)"
    local count=0
    local stall_threshold=7

    while IFS= read -r -d '' file; do
        # Get last commit date for this file
        local last_commit
        last_commit=$(git -C "$WORKSPACE_ROOT/_private" log -1 --format=%ct -- "${file#"$WORKSPACE_ROOT"/_private/}" 2>/dev/null || echo 0)
        if [[ "$last_commit" == "0" ]]; then
            last_commit=$(git -C "$WORKSPACE_ROOT" log -1 --format=%ct -- "$file" 2>/dev/null || echo 0)
        fi

        local days_since=$(( (NOW - last_commit) / 86400 ))
        if [[ $days_since -ge $stall_threshold ]]; then
            local relpath="${file#"$WORKSPACE_ROOT"/}"
            # Try to extract completion % from the plan
            local pct
            pct=$(python3 << PYEOF 2>/dev/null || echo "?"
import sys, types
sys.modules.setdefault('pygit2', types.ModuleType('pygit2'))
sys.path.insert(0, '$WORKSPACE_ROOT/markdown-plan/python/src')
from mdplan.count import count_all_tasks, count_remaining_tasks
with open('$file') as f:
    text = f.read()
total = count_all_tasks(text)
remaining = count_remaining_tasks(text)
done = total - remaining
pct = int(100 * done / total) if total > 0 else 0
print(f'{pct}%')
PYEOF
            )
            if $JSON_MODE; then
                echo "{\"type\":\"stalled\",\"file\":\"$relpath\",\"days\":$days_since,\"completion\":\"$pct\"}"
            else
                status_fail "$relpath" "${pct} complete, ${days_since}d since last change"
            fi
            count=$((count + 1))
        fi
    done < <(find "$TODO_DIR" -name "*.plan.md" -print0 2>/dev/null)

    if [[ $count -eq 0 ]]; then
        $JSON_MODE || status_ok "No stalled plans" "all active plans updated within ${stall_threshold}d"
    else
        WARNINGS=$((WARNINGS + count))
    fi
    echo ""
}

# ── 3. Stale problems (intake >14d, other >30d) ──────────────────
find_stale_problems() {
    header "Stale Problems"
    local count=0

    for dir in "$PROBLEMS_DIR"/*/; do
        [[ -d "$dir" ]] || continue
        local readme="$dir/README.md"
        [[ -f "$readme" ]] || continue

        # Extract status from first 20 lines
        local status
        status=$(head -20 "$readme" | grep -oE '(intake|investigating|planning|implementing|testing)' | head -1 || true)
        [[ -z "$status" ]] && continue

        # Extract date from directory name
        local dirname
        dirname=$(basename "$dir")
        local date_part="${dirname:0:10}"
        local created
        created=$(date -d "$date_part" +%s 2>/dev/null || date -jf "%Y-%m-%d" "$date_part" +%s 2>/dev/null || echo 0)
        [[ "$created" == "0" ]] && continue

        local age_days=$(( (NOW - created) / 86400 ))
        local threshold=30
        [[ "$status" == "intake" ]] && threshold=14

        if [[ $age_days -ge $threshold ]]; then
            local slug="${dirname:11}"
            if $JSON_MODE; then
                echo "{\"type\":\"stale_problem\",\"slug\":\"$slug\",\"status\":\"$status\",\"age_days\":$age_days,\"threshold\":$threshold}"
            else
                status_fail "$slug" "${status} for ${age_days}d (threshold: ${threshold}d)"
            fi
            count=$((count + 1))
        fi
    done

    if [[ $count -eq 0 ]]; then
        $JSON_MODE || status_ok "No stale problems" ""
    else
        WARNINGS=$((WARNINGS + count))
    fi
    echo ""
}

# ── 4. Recurring failure patterns from post-mortems ───────────────
check_postmortem_patterns() {
    header "Post-Mortem Pattern Analysis"

    if [[ ! -d "$POSTMORTEMS_DIR" ]]; then
        $JSON_MODE || status_skip "No post-mortems directory" ""
        echo ""
        return
    fi

    local pm_count=0
    local -A categories=()

    for file in "$POSTMORTEMS_DIR"/*.md; do
        [[ -f "$file" ]] || continue
        [[ "$(basename "$file")" == "README.md" ]] && continue
        pm_count=$((pm_count + 1))

        # Categorize by keywords in filename and content
        local name
        name=$(basename "$file")
        local content
        content=$(head -30 "$file")

        if echo "$name $content" | grep -qi "drift\|version\|bindings"; then
            categories[drift]=$(( ${categories[drift]:-0} + 1 ))
        fi
        if echo "$name $content" | grep -qi "pipeline\|ci\|deploy\|release"; then
            categories[ci_cd]=$(( ${categories[ci_cd]:-0} + 1 ))
        fi
        if echo "$name $content" | grep -qi "concurrency\|deadlock\|race"; then
            categories[concurrency]=$(( ${categories[concurrency]:-0} + 1 ))
        fi
        if echo "$name $content" | grep -qi "token\|auth\|credential"; then
            categories[auth]=$(( ${categories[auth]:-0} + 1 ))
        fi
    done

    if [[ $pm_count -eq 0 ]]; then
        $JSON_MODE || status_info "No post-mortems" ""
    else
        $JSON_MODE || status_info "Total post-mortems" "$pm_count"
        for cat in "${!categories[@]}"; do
            local n="${categories[$cat]}"
            if [[ $n -ge 2 ]]; then
                if $JSON_MODE; then
                    echo "{\"type\":\"recurring_pattern\",\"category\":\"$cat\",\"count\":$n}"
                else
                    status_fail "Recurring: $cat" "${n} incidents — high risk for similar work"
                fi
                WARNINGS=$((WARNINGS + 1))
            else
                $JSON_MODE || status_info "$cat" "${n} incident(s)"
            fi
        done
    fi
    echo ""
}

# ── 5. Blocker chain depth from master plan ───────────────────────
check_blocker_chains() {
    header "Dependency Chain Depth"

    local master_plan="$PLANNING_DIR/todo/2026-02-15-master-plan.md"
    if [[ ! -f "$master_plan" ]]; then
        $JSON_MODE || status_skip "No master plan found" ""
        echo ""
        return
    fi

    # Count items per LAYER (format: "LAYER N — description")
    local max_layer=0
    while IFS= read -r line; do
        local layer_num
        layer_num=$(echo "$line" | sed -n 's/^LAYER \([0-9]\+\).*/\1/p')
        [[ -n "$layer_num" && "$layer_num" -gt "$max_layer" ]] && max_layer=$layer_num
    done < <(grep -E "^LAYER [0-9]" "$master_plan" 2>/dev/null || true)

    if [[ $max_layer -gt 0 ]]; then
        if $JSON_MODE; then
            echo "{\"type\":\"dependency_depth\",\"max_layer\":$max_layer}"
        else
            local risk_level="low"
            [[ $max_layer -ge 4 ]] && risk_level="medium"
            [[ $max_layer -ge 6 ]] && risk_level="high"
            local icon_fn="status_ok"
            [[ "$risk_level" != "low" ]] && icon_fn="status_info"
            [[ "$risk_level" == "high" ]] && icon_fn="status_fail"
            $icon_fn "Max dependency depth" "LAYER $max_layer ($risk_level)"
        fi
    else
        $JSON_MODE || status_info "No LAYER markers" "in master plan"
    fi
    echo ""
}

# ── 6. Plans missing estimation fields ────────────────────────────
#
# Exemptions (estimates don't make sense on these):
#   - *.plan.md          — task DAGs; estimates belong on the narrative companion
#   - master-plan*       — portfolio tracker, not a single work item
#   - *-sp*-*            — SP sub-plans are master plan aggregators (see below)
#   - README.md          — not a plan
#
# SP plans (e.g. sp5-*, sp6-*, sp10-*, sp12-*) are sub-aggregators of the
# master plan. They group related work items and track progress across them,
# but they are not single bounded units of work. Estimates belong on the
# individual completion/implementation plans that the SPs reference, not on
# the SP tracking documents themselves.
#
_is_estimate_exempt() {
    local base="$1"
    case "$base" in
        *.plan.md)       return 0 ;;  # task DAGs — estimates go on narrative doc
        *master-plan*)   return 0 ;;  # portfolio-level meta-document
        *-sp[0-9]*)      return 0 ;;  # SP sub-plan aggregators
        README.md)       return 0 ;;
    esac
    return 1
}

check_estimation_coverage() {
    header "Estimation Coverage"
    local total=0
    local with_estimate=0
    local exempt=0
    local without=()

    while IFS= read -r -d '' file; do
        local base
        base=$(basename "$file")
        if _is_estimate_exempt "$base"; then
            exempt=$((exempt + 1))
            continue
        fi
        total=$((total + 1))
        if grep -qi "Estimated Effort\|estimated_effort" "$file" 2>/dev/null; then
            with_estimate=$((with_estimate + 1))
        else
            without+=("$base")
        fi
    done < <(find "$TODO_DIR" -maxdepth 1 -name "*.md" -print0 2>/dev/null)

    if [[ $total -eq 0 ]]; then
        $JSON_MODE || status_skip "No estimatable plans" "(${exempt} exempt)"
    elif [[ ${#without[@]} -eq 0 ]]; then
        $JSON_MODE || status_ok "All plans estimated" "$with_estimate/$total (${exempt} exempt)"
    else
        $JSON_MODE || status_info "Estimation coverage" "$with_estimate/$total plans (${exempt} exempt)"
        for f in "${without[@]}"; do
            $JSON_MODE || status_skip "  Missing estimate" "$f"
        done
    fi
    echo ""
}

# ── 7. Open MRs aging ────────────────────────────────────────────
check_mr_age() {
    header "Open MR Age"

    # Parse session-init output for open MRs (avoid slow glab calls per repo)
    local mr_count=0
    while IFS= read -r line; do
        if echo "$line" | grep -qE "^\s+\S+\s+!"; then
            local repo mr_info
            repo=$(echo "$line" | awk '{print $1}')
            mr_info=$(echo "$line" | sed 's/^\s*//')
            $JSON_MODE || status_info "$repo" "$mr_info"
            mr_count=$((mr_count + 1))
        fi
    done < <(glab mr list --repo vauchi/vauchi 2>/dev/null; \
             for r in android ios macos private scripts; do \
                 glab mr list --repo "vauchi/$r" 2>/dev/null | tail -n +3; \
             done)

    if [[ $mr_count -eq 0 ]]; then
        $JSON_MODE || status_ok "No open MRs" ""
    fi
    echo ""
}

# ── Summary ───────────────────────────────────────────────────────
run_dashboard() {
    echo ""
    header "Risk Dashboard"
    echo ""

    find_blocked_items
    find_stalled_plans
    find_stale_problems
    check_postmortem_patterns
    check_blocker_chains
    check_estimation_coverage

    echo ""
    if [[ $ISSUES -gt 0 ]]; then
        printf "  ${RED}■${NC} %d issue(s) requiring action\n" "$ISSUES"
    fi
    if [[ $WARNINGS -gt 0 ]]; then
        printf "  ${YELLOW}■${NC} %d warning(s) to monitor\n" "$WARNINGS"
    fi
    if [[ $ISSUES -eq 0 && $WARNINGS -eq 0 ]]; then
        printf "  ${GREEN}■${NC} No risk signals detected\n"
    fi
    echo ""
}

run_dashboard
