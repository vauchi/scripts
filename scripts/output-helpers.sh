#!/usr/bin/env bash
# SPDX-FileCopyrightText: 2026 Mattia Egloff <mattia.egloff@pm.me>
#
# SPDX-License-Identifier: GPL-3.0-or-later

# Shared output formatting helpers for just recipes.
# Source this at the top of [script] recipes for consistent terminal output.
#
# Usage:
#   source scripts/scripts/output-helpers.sh
#
# API:
#   header "Title"                         ── Title ──
#   status_ok  "label" "message"           ✓ label                     message
#   status_fail "label" "message"          ✗ label                     message
#   status_info "label" "message"          · label                     message
#   status_skip "label" "message"          - label                     message
#   summary_ok  count total [elapsed]      ── 25/25 ok (1.2s) ──
#   summary_mix ok fail [elapsed]          ── 23 ok, 2 failed (1.2s) ──
#
#   # Compact mode — collects results, prints summary if all identical
#   out_begin [total]                      start collecting
#   out_ok   "label" "message"             record success
#   out_fail "label" "message"             record failure
#   out_info "label" "message"             record info
#   out_end                                flush: compact or expanded
#
#   # Timing
#   timer_start                            capture start time
#   timer_elapsed                          echo seconds since timer_start

# ── Colors ──────────────────────────────────────────────────────────
# Disable colors if stdout is not a terminal (piped, redirected)
if [[ -t 1 ]]; then
    GREEN='\033[0;32m'
    RED='\033[0;31m'
    YELLOW='\033[1;33m'
    BLUE='\033[0;34m'
    DIM='\033[2m'
    BOLD='\033[1m'
    NC='\033[0m'
else
    GREEN='' RED='' YELLOW='' BLUE='' DIM='' BOLD='' NC=''
fi

# ── Column width ────────────────────────────────────────────────────
_OUT_COL=${_OUT_COL:-25}

# ── Section headers ─────────────────────────────────────────────────
header() {
    printf "── %s ──\n" "$1"
}

# ── Status lines (colored) ──────────────────────────────────────────
status_ok() {
    printf "  ${GREEN}✓${NC} %-${_OUT_COL}s %s\n" "$1" "$2"
}

status_fail() {
    printf "  ${RED}✗${NC} %-${_OUT_COL}s %s\n" "$1" "$2"
}

status_info() {
    printf "  ${DIM}·${NC} %-${_OUT_COL}s %s\n" "$1" "$2"
}

status_skip() {
    printf "  ${DIM}-${NC} %-${_OUT_COL}s %s\n" "$1" "$2"
}

# ── Progress lines (with counter) ──────────────────────────────────
progress_ok() {
    local n="$1" total="$2" label="$3" msg="$4"
    printf "  ${DIM}[%2d/%d]${NC} ${GREEN}✓${NC} %-${_OUT_COL}s %s\n" "$n" "$total" "$label" "$msg"
}

progress_fail() {
    local n="$1" total="$2" label="$3" msg="$4"
    printf "  ${DIM}[%2d/%d]${NC} ${RED}✗${NC} %-${_OUT_COL}s %s\n" "$n" "$total" "$label" "$msg"
}

progress_info() {
    local n="$1" total="$2" label="$3" msg="$4"
    printf "  ${DIM}[%2d/%d]${NC} ${DIM}·${NC} %-${_OUT_COL}s %s\n" "$n" "$total" "$label" "$msg"
}

# ── Summary footers ────────────────────────────────────────────────
summary_ok() {
    local count="$1" total="$2" elapsed="${3:-}"
    local timing=""
    [[ -n "$elapsed" ]] && timing=" (${elapsed}s)"
    printf "\n── ${GREEN}%d/%d ok${NC}%s ──\n" "$count" "$total" "$timing"
}

summary_mix() {
    local ok="$1" fail="$2" elapsed="${3:-}"
    local timing=""
    [[ -n "$elapsed" ]] && timing=" (${elapsed}s)"
    if [[ "$fail" -eq 0 ]]; then
        printf "\n── ${GREEN}%d ok${NC}%s ──\n" "$ok" "$timing"
    else
        printf "\n── ${GREEN}%d ok${NC}, ${RED}%d failed${NC}%s ──\n" "$ok" "$fail" "$timing"
    fi
}

# ── Timing ──────────────────────────────────────────────────────────
_OUT_TIMER_START=""

timer_start() {
    _OUT_TIMER_START=$SECONDS
}

timer_elapsed() {
    echo $(( SECONDS - _OUT_TIMER_START ))
}

# ── Compact mode ────────────────────────────────────────────────────
# Collects results in arrays. On out_end:
# - If ALL results have the same status+message → print single summary line
# - Otherwise → print each line individually
_OUT_LABELS=()
_OUT_MSGS=()
_OUT_TYPES=()    # ok|fail|info|skip
_OUT_TOTAL=0
_OUT_COUNT=0

out_begin() {
    _OUT_LABELS=()
    _OUT_MSGS=()
    _OUT_TYPES=()
    _OUT_TOTAL="${1:-0}"
    _OUT_COUNT=0
}

out_ok() {
    _OUT_COUNT=$((_OUT_COUNT + 1))
    _OUT_LABELS+=("$1")
    _OUT_MSGS+=("$2")
    _OUT_TYPES+=("ok")
}

out_fail() {
    _OUT_COUNT=$((_OUT_COUNT + 1))
    _OUT_LABELS+=("$1")
    _OUT_MSGS+=("$2")
    _OUT_TYPES+=("fail")
}

out_info() {
    _OUT_COUNT=$((_OUT_COUNT + 1))
    _OUT_LABELS+=("$1")
    _OUT_MSGS+=("$2")
    _OUT_TYPES+=("info")
}

out_skip() {
    _OUT_COUNT=$((_OUT_COUNT + 1))
    _OUT_LABELS+=("$1")
    _OUT_MSGS+=("$2")
    _OUT_TYPES+=("skip")
}

out_end() {
    local elapsed="${1:-}"
    # Use count as total if total wasn't specified
    local total=$_OUT_COUNT
    [[ "$_OUT_TOTAL" -gt 0 ]] && total=$_OUT_TOTAL

    # Check if all results are identical (same type + message)
    local all_same=true
    local first_type="${_OUT_TYPES[0]:-}"
    local first_msg="${_OUT_MSGS[0]:-}"
    local ok_count=0 fail_count=0

    for i in "${!_OUT_TYPES[@]}"; do
        [[ "${_OUT_TYPES[$i]}" == "ok" ]] && ok_count=$((ok_count + 1))
        [[ "${_OUT_TYPES[$i]}" == "fail" ]] && fail_count=$((fail_count + 1))
        if [[ "${_OUT_TYPES[$i]}" != "$first_type" || "${_OUT_MSGS[$i]}" != "$first_msg" ]]; then
            all_same=false
        fi
    done

    local timing=""
    [[ -n "$elapsed" ]] && timing=" (${elapsed}s)"

    if [[ "$all_same" == true && $_OUT_COUNT -gt 3 ]]; then
        # Compact: single summary line
        local icon color
        case "$first_type" in
            ok)   icon="✓"; color="$GREEN" ;;
            fail) icon="✗"; color="$RED" ;;
            *)    icon="·"; color="$DIM" ;;
        esac
        printf "  ${color}${icon}${NC} %d/%d repos: %s%s\n" "$_OUT_COUNT" "$total" "$first_msg" "$timing"
    else
        # Expanded: print each line
        for i in "${!_OUT_LABELS[@]}"; do
            case "${_OUT_TYPES[$i]}" in
                ok)   status_ok   "${_OUT_LABELS[$i]}" "${_OUT_MSGS[$i]}" ;;
                fail) status_fail "${_OUT_LABELS[$i]}" "${_OUT_MSGS[$i]}" ;;
                info) status_info "${_OUT_LABELS[$i]}" "${_OUT_MSGS[$i]}" ;;
                skip) status_skip "${_OUT_LABELS[$i]}" "${_OUT_MSGS[$i]}" ;;
            esac
        done
        # Summary footer
        summary_mix "$ok_count" "$fail_count" "${elapsed:-}"
    fi
}
