#!/usr/bin/env bash
# SPDX-FileCopyrightText: 2026 Mattia Egloff <mattia.egloff@pm.me>
#
# SPDX-License-Identifier: GPL-3.0-or-later

# Quiet mode output capture and summary for just recipes.
# Source this file alongside resolve-repo.sh in [script('bash')] recipes.
#
# Activation:
#   VAUCHI_QUIET=1 just check core
#   just check core --quiet
#
# API:
#   _qr_parse_args <args...>   — parse --quiet flag, set _QR_REPO
#   quiet_enabled              — returns 0 if quiet mode active
#   run_step <label> <fn>      — run function, capture output + timing if quiet
#   print_summary <operation>  — print results table (or write to shared dir)
#   qr_print_shared_summary <operation> — aggregate shared dir results into one table

set -euo pipefail

_QR_TMPDIR=""
_QR_STEP_COUNT=0
_QR_TOTAL_START=""
_QR_REPO=""

# Colors
_QR_GREEN='\033[0;32m'
_QR_RED='\033[0;31m'
_QR_DIM='\033[2m'
_QR_BOLD='\033[1m'
_QR_NC='\033[0m'

# Parse recipe args: extract --quiet flag, set _QR_REPO to remaining arg
_qr_parse_args() {
    _QR_REPO=""
    for arg in "$@"; do
        case "$arg" in
            --quiet|-q) export VAUCHI_QUIET=1 ;;
            *)          _QR_REPO="$arg" ;;
        esac
    done
}

# Check if quiet mode is active
quiet_enabled() {
    [[ "${VAUCHI_QUIET:-}" == "1" ]]
}

# Lazy-init temp directory
_qr_init() {
    if quiet_enabled && [[ -z "$_QR_TMPDIR" ]]; then
        _QR_TMPDIR=$(mktemp -d)
        _QR_TOTAL_START=$SECONDS
        trap '_qr_cleanup' EXIT
    fi
}

_qr_cleanup() {
    [[ -n "$_QR_TMPDIR" && -d "$_QR_TMPDIR" ]] && rm -rf "$_QR_TMPDIR"
}

# Run a step. In quiet mode: capture output + timing. In normal mode: run directly.
# Usage: run_step "label" my_function
run_step() {
    local label="$1"
    shift

    if ! quiet_enabled; then
        "$@" || exit 1
        return 0
    fi

    _qr_init

    local idx=$_QR_STEP_COUNT
    _QR_STEP_COUNT=$((_QR_STEP_COUNT + 1))
    local logfile="$_QR_TMPDIR/${idx}.log"
    local metafile="$_QR_TMPDIR/${idx}.meta"

    local step_start=$SECONDS
    local rc=0
    "$@" > "$logfile" 2>&1 || rc=$?
    local step_duration=$(( SECONDS - step_start ))

    echo "${label}|${rc}|${step_duration}" > "$metafile"
    return 0
}

# Print summary table from collected results.
# If _QR_SHARED_DIR is set, writes results to shared dir instead of printing.
print_summary() {
    quiet_enabled || return 0

    local operation="${1:-}"

    # If aggregating for a parent recipe (e.g., check), write to shared dir
    if [[ -n "${_QR_SHARED_DIR:-}" ]]; then
        local outfile="$_QR_SHARED_DIR/${operation}.results"
        for (( i=0; i<_QR_STEP_COUNT; i++ )); do
            cat "$_QR_TMPDIR/${i}.meta" >> "$outfile"
            # Also copy log files for failure output
            cp "$_QR_TMPDIR/${i}.log" "$_QR_SHARED_DIR/${operation}_${i}.log"
        done
        # Return non-zero if any step failed
        local any_failed=0
        for (( i=0; i<_QR_STEP_COUNT; i++ )); do
            local rc
            IFS='|' read -r _ rc _ < "$_QR_TMPDIR/${i}.meta"
            [[ "$rc" -ne 0 ]] && any_failed=1
        done
        return $any_failed
    fi

    _qr_print_table "$operation"
}

# Print the actual table
_qr_print_table() {
    local operation="${1:-}"

    local total_duration=$(( SECONDS - _QR_TOTAL_START ))
    local any_failed=0
    local failed_entries=()

    echo ""
    if [[ -n "$operation" ]]; then
        echo -e "${_QR_BOLD}${operation}${_QR_NC}"
    fi
    printf "%-24s %-8s %s\n" "Repo" "Status" "Duration"
    printf "%-24s %-8s %s\n" "------------------------" "--------" "--------"

    for (( i=0; i<_QR_STEP_COUNT; i++ )); do
        local meta
        meta=$(cat "$_QR_TMPDIR/${i}.meta")
        local label rc duration
        IFS='|' read -r label rc duration <<< "$meta"

        local status_icon
        if [[ "$rc" -eq 0 ]]; then
            status_icon="${_QR_GREEN}pass${_QR_NC}"
        else
            status_icon="${_QR_RED}FAIL${_QR_NC}"
            any_failed=1
            failed_entries+=("$label|$_QR_TMPDIR/${i}.log")
        fi

        printf "%-24s %b   %s\n" "$label" "$status_icon" "${duration}s"
    done

    printf "%-24s %-8s %s\n" "------------------------" "--------" "--------"
    if [[ $any_failed -eq 0 ]]; then
        printf "%-24s %-8s %b\n" "" "" "${_QR_GREEN}Total: ${total_duration}s${_QR_NC}"
    else
        printf "%-24s %-8s %b\n" "" "" "${_QR_RED}Failed in ${total_duration}s${_QR_NC}"
    fi
    echo ""

    # Show captured output for failures
    if [[ ${#failed_entries[@]} -gt 0 ]]; then
        for entry in "${failed_entries[@]}"; do
            local flabel flog
            IFS='|' read -r flabel flog <<< "$entry"
            echo -e "${_QR_RED}=== Output from failed: $flabel ===${_QR_NC}"
            cat "$flog"
            echo ""
        done
    fi

    return $any_failed
}

# Aggregate results from shared dir (called by composite recipes like check)
qr_print_shared_summary() {
    local operation="${1:-check}"
    local shared_dir="${_QR_SHARED_DIR:?_QR_SHARED_DIR not set}"
    local total_duration=$(( SECONDS - _QR_TOTAL_START ))
    local any_failed=0
    local failed_entries=()

    echo ""
    echo -e "${_QR_BOLD}${operation}${_QR_NC}"
    printf "%-12s %-20s %-8s %s\n" "Phase" "Repo" "Status" "Duration"
    printf "%-12s %-20s %-8s %s\n" "------------" "--------------------" "--------" "--------"

    for results_file in "$shared_dir"/*.results; do
        [[ -f "$results_file" ]] || continue
        local phase
        phase=$(basename "$results_file" .results)
        local line_idx=0
        while IFS='|' read -r label rc duration; do
            [[ -z "$label" ]] && continue
            local status_icon
            if [[ "$rc" -eq 0 ]]; then
                status_icon="${_QR_GREEN}pass${_QR_NC}"
            else
                status_icon="${_QR_RED}FAIL${_QR_NC}"
                any_failed=1
                failed_entries+=("${phase}/${label}|${shared_dir}/${phase}_${line_idx}.log")
            fi
            printf "%-12s %-20s %b   %s\n" "$phase" "$label" "$status_icon" "${duration}s"
            line_idx=$((line_idx + 1))
        done < "$results_file"
    done

    printf "%-12s %-20s %-8s %s\n" "------------" "--------------------" "--------" "--------"
    if [[ $any_failed -eq 0 ]]; then
        printf "%-12s %-20s %-8s %b\n" "" "" "" "${_QR_GREEN}Total: ${total_duration}s${_QR_NC}"
    else
        printf "%-12s %-20s %-8s %b\n" "" "" "" "${_QR_RED}Failed in ${total_duration}s${_QR_NC}"
    fi
    echo ""

    if [[ ${#failed_entries[@]} -gt 0 ]]; then
        for entry in "${failed_entries[@]}"; do
            local flabel flog
            IFS='|' read -r flabel flog <<< "$entry"
            echo -e "${_QR_RED}=== Output from failed: $flabel ===${_QR_NC}"
            [[ -f "$flog" ]] && cat "$flog"
            echo ""
        done
    fi

    return $any_failed
}
