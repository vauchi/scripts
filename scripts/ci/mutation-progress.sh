#!/usr/bin/env bash
# SPDX-FileCopyrightText: 2026 Mattia Egloff <mattia.egloff@pm.me>
#
# SPDX-License-Identifier: GPL-3.0-or-later

# mutation-progress.sh — Monitor cargo-mutants progress with GitLab CI section output.
#
# Usage:
#   mutation-progress.sh <mutants_pid> <mutants_out_dir>
#
# Monitors the cargo-mutants process identified by <mutants_pid>, reading
# result files from <mutants_out_dir>. Displays real-time progress with
# GitLab CI collapsible sections and a final summary.
#
# Exit code: 0 once the process is gone. The process is the caller's
# child, not this script's, so only the caller can `wait` for it and
# read its status (vauchi/private#487).
#
# MUTATION_PROGRESS_POLL_SECS shortens the polling interval for tests.

set -euo pipefail

MUTANTS_PID="${1:?Usage: mutation-progress.sh <pid> <output_dir>}"
MUTANTS_OUT="${2:?Usage: mutation-progress.sh <pid> <output_dir>}"
POLL_SECS="${MUTATION_PROGRESS_POLL_SECS:-30}"
DISCOVERY_POLL_SECS="${MUTATION_PROGRESS_POLL_SECS:-10}"

# Colors
G='\033[32m'; R='\033[31m'; Y='\033[33m'; D='\033[2m'
B='\033[1m'; C='\033[36m'; Z='\033[0m'

count() { if [ -f "$1" ]; then wc -l < "$1" | tr -d ' '; else echo 0; fi; }

color_type() {
  case "$1" in
    caught)  printf '%b' "${G}caught${Z}" ;;
    missed)  printf '%b' "${R}MISSED${Z}" ;;
    timeout) printf '%b' "${Y}timeout${Z}" ;;
    *)       printf '%b' "${D}unviable${Z}" ;;
  esac
}

last_mutant() {
  local f
  f=$(find "$MUTANTS_OUT" -maxdepth 1 -name '*.txt' \
        \( -name caught.txt -o -name missed.txt -o -name timeout.txt -o -name unviable.txt \) \
        -printf '%T@ %p\n' 2>/dev/null | sort -rn | head -1 | cut -d' ' -f2-)
  if [ -n "$f" ]; then
    printf "  \xe2\x94\x94 %s \xe2\x80\x94 %b\n" "$(tail -1 "$f")" "$(color_type "$(basename "$f" .txt)")"
  fi
}

running() { kill -0 "$MUTANTS_PID" 2>/dev/null; }

print_summary() {
  local c m t u d cpct
  c=$(count "$MUTANTS_OUT/caught.txt"); m=$(count "$MUTANTS_OUT/missed.txt")
  t=$(count "$MUTANTS_OUT/timeout.txt"); u=$(count "$MUTANTS_OUT/unviable.txt")
  d=$((c + m + t + u))
  [ "$TOTAL" -gt 0 ] 2>/dev/null && cpct=$((c * 100 / TOTAL)) || cpct=0

  echo ""
  printf '%b' "${B}=== Mutation Testing Summary ===${Z}\n"
  printf "  Total:    %d / %d\n" "$d" "$TOTAL"
  printf '  Caught:   %b%d (%d%%)%b\n' "$G" "$c" "$cpct" "$Z"
  printf '  Missed:   %b%d%b\n' "$R" "$m" "$Z"
  printf '  Timeout:  %b%d%b\n' "$Y" "$t" "$Z"
  printf '  Unviable: %b%d%b\n' "$D" "$u" "$Z"
  if [ -s "$MUTANTS_OUT/missed.txt" ]; then
    echo ""
    printf '%b' "${R}${B}Missed mutants:${Z}\n"
    while IFS= read -r line; do printf '  %b%s%b\n' "$R" "$line" "$Z"; done < "$MUTANTS_OUT/missed.txt"
  fi
}

TOTAL=0

# Wait for mutants.json to be written (indicates mutant discovery is done)
while [ ! -f "$MUTANTS_OUT/mutants.json" ] && running; do
  sleep "$DISCOVERY_POLL_SECS"
done
if ! running && [ ! -f "$MUTANTS_OUT/mutants.json" ]; then
  print_summary
  exit 0
fi

TOTAL=$(python3 -c "import json; print(len(json.load(open('$MUTANTS_OUT/mutants.json'))))" 2>/dev/null || echo "0")

printf "\033[0Ksection_start:%s:baseline[collapsed=true]\r\033[0K" "$(date +%s)"
printf '%b' "${B}${C}Baseline: compiling and running unmutated tests${Z}\n"

SECONDS=0; BASELINE_OPEN=true; TESTING_OPEN=false

while running; do
  sleep "$POLL_SECS"
  c=$(count "$MUTANTS_OUT/caught.txt"); m=$(count "$MUTANTS_OUT/missed.txt")
  t=$(count "$MUTANTS_OUT/timeout.txt"); u=$(count "$MUTANTS_OUT/unviable.txt")
  d=$((c + m + t + u))

  if [ "$d" -eq 0 ]; then
    printf "Waiting... (%dm elapsed)\n" "$((SECONDS / 60))"
    continue
  fi

  if $BASELINE_OPEN; then
    printf "\033[0Ksection_end:%s:baseline\r\033[0K" "$(date +%s)"
    printf "\033[0Ksection_start:%s:testing\r\033[0K" "$(date +%s)"
    printf '%b' "${B}${C}Testing ${TOTAL} mutants${Z}\n"
    BASELINE_OPEN=false; TESTING_OPEN=true
  fi

  pct=$((d * 100 / TOTAL))
  eta=""
  if [ "$SECONDS" -gt 0 ] && [ "$d" -gt 0 ]; then
    rem=$(( (TOTAL - d) * SECONDS / d / 60 ))
    eta="  ${D}(~${rem}m remaining)${Z}"
  fi

  printf '[%3d/%d %2d%%] %b%d caught%b, %b%d missed%b, %b%d timeout%b, %b%d unviable%b%b\n' \
    "$d" "$TOTAL" "$pct" "$G" "$c" "$Z" "$R" "$m" "$Z" "$Y" "$t" "$Z" "$D" "$u" "$Z" "$eta"
  last_mutant
done

$BASELINE_OPEN && printf "\033[0Ksection_end:%s:baseline\r\033[0K" "$(date +%s)"
$TESTING_OPEN && printf "\033[0Ksection_end:%s:testing\r\033[0K" "$(date +%s)"

print_summary
