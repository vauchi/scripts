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
#   CI_API_V4_URL, CI_PROJECT_ID, CI_PIPELINE_ID, CI_JOB_TOKEN
#
# The script queries the GitLab API to determine pipeline status and
# coverage percentage, then writes SVG files that can be served via
# GitLab Pages without requiring public_jobs=true.

set -euo pipefail

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

# --- Determine pipeline status ---
PIPELINE_STATUS="unknown"
if [ -n "${CI_JOB_TOKEN:-}" ] && [ -n "${CI_API_V4_URL:-}" ]; then
  PIPELINE_JSON=$(curl -sf -H "JOB-TOKEN: ${CI_JOB_TOKEN}" \
    "${CI_API_V4_URL}/projects/${CI_PROJECT_ID}/pipelines/${CI_PIPELINE_ID}" 2>/dev/null || echo '{}')
  PIPELINE_STATUS=$(echo "$PIPELINE_JSON" | python3 -c "import sys,json; print(json.load(sys.stdin).get('status','unknown'))" 2>/dev/null || echo "unknown")
fi

case "$PIPELINE_STATUS" in
  success)  STATUS_COLOR="#4c1";     STATUS_LABEL="passed" ;;
  failed)   STATUS_COLOR="#e05d44";  STATUS_LABEL="failed" ;;
  running)  STATUS_COLOR="#dfb317";  STATUS_LABEL="running" ;;
  canceled) STATUS_COLOR="#9f9f9f";  STATUS_LABEL="canceled" ;;
  *)        STATUS_COLOR="#9f9f9f";  STATUS_LABEL="unknown" ;;
esac

echo "Pipeline status: ${STATUS_LABEL}"
generate_badge "pipeline" "$STATUS_LABEL" "$STATUS_COLOR" "${OUTPUT_DIR}/pipeline.svg"

# --- Determine coverage (optional) ---
# The badge job runs with needs:[] so the current pipeline has no coverage yet.
# Query the latest COMPLETED main pipeline's jobs for coverage data.
# GitLab often has coverage at job level but not pipeline level.
COVERAGE=""
if [ -n "${CI_JOB_TOKEN:-}" ] && [ -n "${CI_API_V4_URL:-}" ]; then
  # Find the latest successful main pipeline
  LAST_PID=$(curl -sf -H "JOB-TOKEN: ${CI_JOB_TOKEN}" \
    "${CI_API_V4_URL}/projects/${CI_PROJECT_ID}/pipelines?ref=${CI_DEFAULT_BRANCH}&status=success&per_page=1" 2>/dev/null \
    | python3 -c "import sys,json; d=json.load(sys.stdin); print(d[0]['id'] if d else '')" 2>/dev/null || echo "")

  if [ -n "$LAST_PID" ]; then
    # Get the highest coverage from any job in that pipeline
    COVERAGE=$(curl -sf -H "JOB-TOKEN: ${CI_JOB_TOKEN}" \
      "${CI_API_V4_URL}/projects/${CI_PROJECT_ID}/pipelines/${LAST_PID}/jobs?per_page=100" 2>/dev/null \
      | python3 -c "
import sys, json
jobs = json.load(sys.stdin)
coverages = [j['coverage'] for j in jobs if j.get('coverage') is not None]
if coverages:
    # Use the max coverage (typically the main coverage job, not mobile subset)
    print(f'{max(coverages):.1f}')
" 2>/dev/null || echo "")
  fi
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
else
  echo "No coverage data available"
fi

# --- Determine latest tags (optional) ---
# Fetch latest stable (vX.Y.Z) and dev (vX.Y.Z-dev.N) tags
if [ -n "${CI_JOB_TOKEN:-}" ] && [ -n "${CI_API_V4_URL:-}" ]; then
  TAGS_JSON=$(curl -sf -H "JOB-TOKEN: ${CI_JOB_TOKEN}" \
    "${CI_API_V4_URL}/projects/${CI_PROJECT_ID}/repository/tags?per_page=50&order_by=version" 2>/dev/null || echo '[]')

  read -r PROD_TAG DEV_TAG <<< "$(echo "$TAGS_JSON" | python3 -c "
import sys, json, re
tags = json.load(sys.stdin)
prod = dev = ''
for t in tags:
    name = t.get('name', '')
    if not prod and re.match(r'^v\d+\.\d+\.\d+$', name):
        prod = name
    elif not dev and re.match(r'^v\d+\.\d+\.\d+-dev\.\d+$', name):
        dev = name
    if prod and dev:
        break
print(f'{prod} {dev}')
" 2>/dev/null || echo " ")"

  if [ -n "$PROD_TAG" ]; then
    echo "Latest release: ${PROD_TAG}"
    generate_badge "release" "$PROD_TAG" "#0e80c0" "${OUTPUT_DIR}/release.svg"
  fi

  if [ -n "$DEV_TAG" ]; then
    echo "Latest dev: ${DEV_TAG}"
    generate_badge "dev" "$DEV_TAG" "#6e5494" "${OUTPUT_DIR}/dev.svg"
  fi
fi

echo "Badges written to ${OUTPUT_DIR}/"
ls -la "${OUTPUT_DIR}/"
