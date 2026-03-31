#!/usr/bin/env bash
# SPDX-FileCopyrightText: 2026 Mattia Egloff <mattia.egloff@pm.me>
#
# SPDX-License-Identifier: GPL-3.0-or-later
#
# generate-badges.sh — Generate shields.io-style SVG badges for GitLab Pages
#
# Called by the CI badges template. Produces pipeline status and optional
# coverage badges as static SVGs in public/badges/.
#
# Usage:
#   generate-badges.sh <output_dir>
#
# Environment (set by CI):
#   CI_API_V4_URL, CI_PROJECT_ID, CI_DEFAULT_BRANCH, CI_JOB_TOKEN
#
# Dependencies: bash, curl, jq
#
# The script queries the GitLab API to determine pipeline status and
# coverage percentage, then writes SVG files that can be served via
# GitLab Pages without requiring public_jobs=true.

set -euo pipefail

command -v jq >/dev/null 2>&1 || { echo "ERROR: jq required but not found" >&2; exit 1; }

OUTPUT_DIR="${1:?Usage: generate-badges.sh <output_dir>}"
mkdir -p "$OUTPUT_DIR"

# --- SVG badge generator ---
# Produces a shields.io-compatible flat badge SVG.
# Arguments: label value color output_file
generate_badge() {
  local label="$1" value="$2" color="$3" output="$4"

  # Approximate character widths (font-size 11, DejaVu Sans)
  local label_len=${#label}
  local value_len=${#value}
  local label_width=$(( label_len * 63 / 10 + 10 ))
  local value_width=$(( value_len * 63 / 10 + 10 ))
  local total_width=$(( label_width + value_width ))
  local label_x=$(( label_width * 5 ))
  local value_x=$(( (label_width * 2 + value_width) * 5 ))

  cat > "$output" << SVGEOF
<svg xmlns="http://www.w3.org/2000/svg" width="${total_width}" height="20" role="img" aria-label="${label}: ${value}">
  <title>${label}: ${value}</title>
  <linearGradient id="s" x2="0" y2="100%">
    <stop offset="0" stop-color="#bbb" stop-opacity=".1"/>
    <stop offset="1" stop-opacity=".1"/>
  </linearGradient>
  <clipPath id="r"><rect width="${total_width}" height="20" rx="3" fill="#fff"/></clipPath>
  <g clip-path="url(#r)">
    <rect width="${label_width}" height="20" fill="#555"/>
    <rect x="${label_width}" width="${value_width}" height="20" fill="${color}"/>
    <rect width="${total_width}" height="20" fill="url(#s)"/>
  </g>
  <g fill="#fff" text-anchor="middle" font-family="Verdana,Geneva,DejaVu Sans,sans-serif" text-rendering="geometricPrecision" font-size="110">
    <text aria-hidden="true" x="${label_x}" y="150" fill="#010101" fill-opacity=".3" transform="scale(.1)">${label}</text>
    <text x="${label_x}" y="140" transform="scale(.1)" fill="#fff">${label}</text>
    <text aria-hidden="true" x="${value_x}" y="150" fill="#010101" fill-opacity=".3" transform="scale(.1)">${value}</text>
    <text x="${value_x}" y="140" transform="scale(.1)" fill="#fff">${value}</text>
  </g>
</svg>
SVGEOF
}

# --- JSON endpoint generator ---
# Produces a shields.io endpoint JSON file (schemaVersion 1).
# Arguments: label message color output_file
generate_endpoint() {
  local label="$1" message="$2" color="$3" output="$4"
  jq -n --arg l "$label" --arg m "$message" --arg c "$color" \
    '{schemaVersion:1,label:$l,message:$m,color:$c}' > "$output"
}

# --- Determine pipeline status ---
# Query the most recent completed pipeline on the default branch.
# This job uses needs:[] so the current pipeline is always "running" —
# we skip it to show the last meaningful result.
PIPELINE_STATUS="unknown"
if [ -n "${CI_JOB_TOKEN:-}" ] && [ -n "${CI_API_V4_URL:-}" ]; then
  PIPELINE_STATUS=$(curl -sf -H "JOB-TOKEN: ${CI_JOB_TOKEN}" \
    "${CI_API_V4_URL}/projects/${CI_PROJECT_ID}/pipelines?ref=${CI_DEFAULT_BRANCH}&per_page=5" \
    | jq -r '[.[] | select(.status == "success" or .status == "failed" or .status == "canceled")][0].status // "unknown"' \
    2>/dev/null || echo "unknown")
fi

case "$PIPELINE_STATUS" in
  success)  STATUS_COLOR="#4c1";     STATUS_LABEL="passed" ;;
  failed)   STATUS_COLOR="#e05d44";  STATUS_LABEL="failed" ;;
  canceled) STATUS_COLOR="#9f9f9f";  STATUS_LABEL="canceled" ;;
  *)        STATUS_COLOR="#9f9f9f";  STATUS_LABEL="unknown" ;;
esac

echo "Pipeline status: ${STATUS_LABEL}"
generate_badge "pipeline" "$STATUS_LABEL" "$STATUS_COLOR" "${OUTPUT_DIR}/pipeline.svg"
case "$PIPELINE_STATUS" in
  success) EP_COLOR="brightgreen" ;; failed) EP_COLOR="red" ;; *) EP_COLOR="lightgrey" ;;
esac
generate_endpoint "pipeline" "$STATUS_LABEL" "$EP_COLOR" "${OUTPUT_DIR}/pipeline.json"

# --- Determine coverage ---
# Search recent successful pipelines for coverage data. Coverage jobs
# only run when source files change, so the most recent pipeline may
# not have coverage. Check up to 5 pipelines to find the latest value.
COVERAGE=""
if [ -n "${CI_JOB_TOKEN:-}" ] && [ -n "${CI_API_V4_URL:-}" ]; then
  RECENT_PIDS=$(curl -sf -H "JOB-TOKEN: ${CI_JOB_TOKEN}" \
    "${CI_API_V4_URL}/projects/${CI_PROJECT_ID}/pipelines?ref=${CI_DEFAULT_BRANCH}&status=success&per_page=5" \
    | jq -r '.[].id' 2>/dev/null || echo "")

  for PID in $RECENT_PIDS; do
    COV_RAW=$(curl -sf -H "JOB-TOKEN: ${CI_JOB_TOKEN}" \
      "${CI_API_V4_URL}/projects/${CI_PROJECT_ID}/pipelines/${PID}/jobs?per_page=100" \
      | jq -r '[.[].coverage | select(. != null)] | if length > 0 then max else empty end' \
      2>/dev/null || echo "")
    if [ -n "$COV_RAW" ]; then
      COVERAGE=$(printf "%.1f" "$COV_RAW")
      break
    fi
  done
fi

if [ -n "$COVERAGE" ]; then
  COV_INT=${COVERAGE%.*}
  if [ "$COV_INT" -ge 90 ]; then
    COV_COLOR="#4c1"
  elif [ "$COV_INT" -ge 75 ]; then
    COV_COLOR="#a3c51c"
  elif [ "$COV_INT" -ge 60 ]; then
    COV_COLOR="#dfb317"
  elif [ "$COV_INT" -ge 40 ]; then
    COV_COLOR="#fe7d37"
  else
    COV_COLOR="#e05d44"
  fi

  echo "Coverage: ${COVERAGE}%"
  generate_badge "coverage" "${COVERAGE}%" "$COV_COLOR" "${OUTPUT_DIR}/coverage.svg"
  if [ "$COV_INT" -ge 90 ]; then EP_COV="brightgreen"
  elif [ "$COV_INT" -ge 75 ]; then EP_COV="green"
  elif [ "$COV_INT" -ge 60 ]; then EP_COV="yellow"
  elif [ "$COV_INT" -ge 40 ]; then EP_COV="orange"
  else EP_COV="red"; fi
  generate_endpoint "coverage" "${COVERAGE}%" "$EP_COV" "${OUTPUT_DIR}/coverage.json"
else
  echo "No coverage data — generating fallback badge"
  generate_badge "coverage" "N/A" "#9f9f9f" "${OUTPUT_DIR}/coverage.svg"
  generate_endpoint "coverage" "N/A" "lightgrey" "${OUTPUT_DIR}/coverage.json"
fi

# --- Determine latest tags ---
# Fetch latest stable (vX.Y.Z) and dev (vX.Y.Z-dev.N) tags.
# Always generate badge files so URLs never 404.
if [ -n "${CI_JOB_TOKEN:-}" ] && [ -n "${CI_API_V4_URL:-}" ]; then
  TAGS_JSON=$(curl -sf -H "JOB-TOKEN: ${CI_JOB_TOKEN}" \
    "${CI_API_V4_URL}/projects/${CI_PROJECT_ID}/repository/tags?per_page=50&order_by=version" \
    2>/dev/null || echo '[]')

  PROD_TAG=$(echo "$TAGS_JSON" \
    | jq -r '[.[] | .name | select(test("^v[0-9]+\\.[0-9]+\\.[0-9]+$"))][0] // empty' \
    2>/dev/null || echo "")
  DEV_TAG=$(echo "$TAGS_JSON" \
    | jq -r '[.[] | .name | select(test("^v[0-9]+\\.[0-9]+\\.[0-9]+-dev\\.[0-9]+$"))][0] // empty' \
    2>/dev/null || echo "")

  if [ -n "$PROD_TAG" ]; then
    echo "Latest release: ${PROD_TAG}"
    generate_badge "release" "$PROD_TAG" "#0e80c0" "${OUTPUT_DIR}/release.svg"
    generate_endpoint "release" "$PROD_TAG" "blue" "${OUTPUT_DIR}/release.json"
  else
    generate_badge "release" "none" "#9f9f9f" "${OUTPUT_DIR}/release.svg"
    generate_endpoint "release" "none" "lightgrey" "${OUTPUT_DIR}/release.json"
  fi

  if [ -n "$DEV_TAG" ]; then
    echo "Latest dev: ${DEV_TAG}"
    generate_badge "dev" "$DEV_TAG" "#6e5494" "${OUTPUT_DIR}/dev.svg"
    generate_endpoint "dev" "$DEV_TAG" "blueviolet" "${OUTPUT_DIR}/dev.json"
  else
    generate_badge "dev" "none" "#9f9f9f" "${OUTPUT_DIR}/dev.svg"
    generate_endpoint "dev" "none" "lightgrey" "${OUTPUT_DIR}/dev.json"
  fi
else
  # API unavailable — generate placeholders so badge URLs still resolve
  generate_badge "coverage" "N/A" "#9f9f9f" "${OUTPUT_DIR}/coverage.svg"
  generate_endpoint "coverage" "N/A" "lightgrey" "${OUTPUT_DIR}/coverage.json"
  generate_badge "release" "N/A" "#9f9f9f" "${OUTPUT_DIR}/release.svg"
  generate_endpoint "release" "N/A" "lightgrey" "${OUTPUT_DIR}/release.json"
  generate_badge "dev" "N/A" "#9f9f9f" "${OUTPUT_DIR}/dev.svg"
  generate_endpoint "dev" "N/A" "lightgrey" "${OUTPUT_DIR}/dev.json"
fi

echo "Badges written to ${OUTPUT_DIR}/"
ls -la "${OUTPUT_DIR}/"
