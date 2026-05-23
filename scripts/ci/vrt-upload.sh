#!/bin/bash
# SPDX-FileCopyrightText: 2026 Mattia Egloff <mattia.egloff@pm.me>
#
# SPDX-License-Identifier: GPL-3.0-or-later
#
# Upload screenshots to Visual Regression Tracker.
#
# Runs as after_script in CI snapshot jobs. Advisory only —
# failures warn but never break the pipeline.
#
# Required environment:
#   VRT_API_URL          — VRT instance (e.g., https://vrt.vauchi.app)
#   VRT_API_KEY          — project API key (masked CI variable)
#   VRT_PROJECT          — project name (default: vauchi)
#   VRT_SCREENSHOT_DIR   — directory containing *.png files
#   VRT_PLATFORM         — platform label (ios, macos, android, web-demo)
#
# Optional:
#   VRT_BRANCH           — branch name (default: CI_MERGE_REQUEST_SOURCE_BRANCH_NAME or CI_COMMIT_REF_NAME)
#   VRT_CI_BUILD_ID      — unique build id (default: CI_PIPELINE_ID)
#   VRT_DIFF_TOLERANCE   — diff tolerance percent (default: 0.5)
#
# API reference (from sdk-js source):
#   POST /builds          — create build (header: apiKey, body: project+branch+ciBuildId)
#   POST /test-runs       — upload screenshot (base64)
#   PATCH /builds/:id     — close build

set -euo pipefail

# ── Skip gracefully if not configured ─────────────────────────

if [ -z "${VRT_API_KEY:-}" ]; then
    echo "[vrt-upload] VRT_API_KEY not set — skipping upload"
    exit 0
fi

if [ -z "${VRT_API_URL:-}" ]; then
    echo "[vrt-upload] VRT_API_URL not set — skipping upload"
    exit 0
fi

if [ -z "${VRT_SCREENSHOT_DIR:-}" ]; then
    echo "[vrt-upload] VRT_SCREENSHOT_DIR not set — skipping upload"
    exit 0
fi

if [ ! -d "$VRT_SCREENSHOT_DIR" ]; then
    echo "[vrt-upload] Screenshot directory not found: $VRT_SCREENSHOT_DIR"
    exit 0
fi

# ── Configuration ─────────────────────────────────────────────

VRT_PROJECT="${VRT_PROJECT:-vauchi}"
VRT_BRANCH="${VRT_BRANCH:-${CI_MERGE_REQUEST_SOURCE_BRANCH_NAME:-${CI_COMMIT_REF_NAME:-main}}}"
VRT_CI_BUILD_ID="${VRT_CI_BUILD_ID:-${CI_PIPELINE_ID:-local-$(date +%s)}}"
VRT_PLATFORM="${VRT_PLATFORM:-unknown}"
VRT_DIFF_TOLERANCE="${VRT_DIFF_TOLERANCE:-0.5}"

# Derive a VRT test name from a screenshot path.
#
# $1 = absolute or workdir-relative path to a .png file
# $2 = VRT_SCREENSHOT_DIR (root the path is interpreted against)
#
# Maps "<root>/<rel>/<stem>.png" to "<rel> <stem>" with `_`, `/`, `-`
# all collapsed to a single space. Flat layout (`<root>/my_card.png`)
# yields "my card" — identical to the pre-2026-05-23 behaviour. Theme
# subdirs (`<root>/dark/my_card.png`) yield "dark my card" so the same
# screen captured under two themes uploads as distinct VRT test names.
vrt_test_name() {
    local png="$1" root="$2"
    local rel="${png#"$root"/}"
    # tr '_/-' '   ' is POSIX-portable; tr -s squashes repeats.
    printf '%s' "${rel%.png}" | tr '_/-' '   ' | tr -s ' '
}

# Count screenshots (depth ≤ 2 so optional theme subdirs are walked —
# see `2026-05-01-dark-mode-snapshot-parity` G7.5 for the linux-qt
# `baseline/{dark,light}/` layout that drove the bump).
PNG_COUNT=$(find "$VRT_SCREENSHOT_DIR" -maxdepth 2 -type f -name "*.png" | wc -l | tr -d ' ')

if [ "$PNG_COUNT" -eq 0 ]; then
    echo "[vrt-upload] No PNG files in $VRT_SCREENSHOT_DIR — skipping"
    exit 0
fi

echo "[vrt-upload] Uploading $PNG_COUNT screenshots from $VRT_PLATFORM"
echo "[vrt-upload] Branch: $VRT_BRANCH | Build: $VRT_CI_BUILD_ID"

# ── Step 0: Health check ─────────────────────────────────────

if ! curl -s --max-time 10 "${VRT_API_URL}/health" > /dev/null 2>&1; then
    echo "[vrt-upload] WARNING: VRT not reachable at ${VRT_API_URL}/health — skipping upload"
    exit 0
fi

# ── Step 1: Create build ──────────────────────────────────────

# Use -w to capture HTTP status separately; avoid -f which discards
# the response body (making API errors impossible to diagnose).
BUILD_RESPONSE=$(curl -s -X POST \
    "${VRT_API_URL}/builds" \
    -H "Content-Type: application/json" \
    -H "apiKey: ${VRT_API_KEY}" \
    -d "{
        \"branchName\": \"${VRT_BRANCH}\",
        \"project\": \"${VRT_PROJECT}\",
        \"ciBuildId\": \"${VRT_CI_BUILD_ID}-${VRT_PLATFORM}\"
    }" \
    -w '\n%{http_code}' 2>&1)

# Split response body and HTTP code
HTTP_CODE=$(echo "$BUILD_RESPONSE" | tail -1)
BUILD_BODY=$(echo "$BUILD_RESPONSE" | sed '$d')

if [ "$HTTP_CODE" -lt 200 ] 2>/dev/null || [ "$HTTP_CODE" -ge 300 ] 2>/dev/null; then
    echo "[vrt-upload] WARNING: Build creation failed (HTTP $HTTP_CODE)"
    echo "[vrt-upload]   Response: ${BUILD_BODY}"
    exit 0
fi

BUILD_ID=$(echo "$BUILD_BODY" | jq -r '.id // empty')
PROJECT_ID=$(echo "$BUILD_BODY" | jq -r '.projectId // empty')

if [ -z "$BUILD_ID" ]; then
    echo "[vrt-upload] WARNING: No build ID in response — ${BUILD_BODY}"
    exit 0
fi

echo "[vrt-upload] Build created: ${BUILD_ID}"

# ── Step 2: Upload screenshots ────────────────────────────────

UPLOADED=0
FAILED=0

while IFS= read -r png; do
    [ -f "$png" ] || continue

    NAME=$(vrt_test_name "$png" "$VRT_SCREENSHOT_DIR")
    IMAGE_B64=$(base64 < "$png" | tr -d '\n')

    UPLOAD_RESPONSE=$(curl -s -X POST \
        "${VRT_API_URL}/test-runs" \
        -H "Content-Type: application/json" \
        -H "apiKey: ${VRT_API_KEY}" \
        -d "{
            \"buildId\": \"${BUILD_ID}\",
            \"projectId\": \"${PROJECT_ID}\",
            \"branchName\": \"${VRT_BRANCH}\",
            \"name\": \"[${VRT_PLATFORM}] ${NAME}\",
            \"imageBase64\": \"${IMAGE_B64}\",
            \"os\": \"${VRT_PLATFORM}\",
            \"diffTollerancePercent\": ${VRT_DIFF_TOLERANCE}
        }" \
        -w '\n%{http_code}' 2>&1)

    UPLOAD_CODE=$(echo "$UPLOAD_RESPONSE" | tail -1)
    if [ "$UPLOAD_CODE" -lt 200 ] 2>/dev/null || [ "$UPLOAD_CODE" -ge 300 ] 2>/dev/null; then
        UPLOAD_BODY=$(echo "$UPLOAD_RESPONSE" | sed '$d')
        echo "[vrt-upload]   WARN: Failed to upload $(basename "$png") (HTTP $UPLOAD_CODE)"
        # Show first failure detail, suppress rest to avoid log spam
        if [ "$FAILED" -eq 0 ]; then
            echo "[vrt-upload]   Detail: ${UPLOAD_BODY}"
        fi
        FAILED=$((FAILED + 1))
        continue
    fi

    UPLOADED=$((UPLOADED + 1))
done < <(find "$VRT_SCREENSHOT_DIR" -maxdepth 2 -type f -name "*.png" | sort)

# ── Step 3: Close build ───────────────────────────────────────

curl -s -X PATCH \
    "${VRT_API_URL}/builds/${BUILD_ID}" \
    -H "Content-Type: application/json" \
    -H "apiKey: ${VRT_API_KEY}" \
    -d '{}' >/dev/null 2>&1 || echo "[vrt-upload] WARNING: Failed to close build"

# ── Summary ───────────────────────────────────────────────────

echo "[vrt-upload] Done: $UPLOADED uploaded, $FAILED failed"
echo "[vrt-upload] Dashboard: ${VRT_API_URL}"
