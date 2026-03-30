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
#   POST /builds          — create build (headers: apiKey, project)
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

# Count screenshots
PNG_COUNT=$(find "$VRT_SCREENSHOT_DIR" -maxdepth 1 -name "*.png" | wc -l | tr -d ' ')

if [ "$PNG_COUNT" -eq 0 ]; then
    echo "[vrt-upload] No PNG files in $VRT_SCREENSHOT_DIR — skipping"
    exit 0
fi

echo "[vrt-upload] Uploading $PNG_COUNT screenshots from $VRT_PLATFORM"
echo "[vrt-upload] Branch: $VRT_BRANCH | Build: $VRT_CI_BUILD_ID"

# ── Step 1: Create build ──────────────────────────────────────

BUILD_RESPONSE=$(curl -sf -X POST \
    "${VRT_API_URL}/builds" \
    -H "Content-Type: application/json" \
    -H "apiKey: ${VRT_API_KEY}" \
    -H "project: ${VRT_PROJECT}" \
    -d "{
        \"branchName\": \"${VRT_BRANCH}\",
        \"project\": \"${VRT_PROJECT}\",
        \"ciBuildId\": \"${VRT_CI_BUILD_ID}-${VRT_PLATFORM}\"
    }" 2>&1) || {
    echo "[vrt-upload] WARNING: Failed to create build — ${BUILD_RESPONSE}"
    exit 0
}

BUILD_ID=$(echo "$BUILD_RESPONSE" | jq -r '.id // empty')
PROJECT_ID=$(echo "$BUILD_RESPONSE" | jq -r '.projectId // empty')

if [ -z "$BUILD_ID" ]; then
    echo "[vrt-upload] WARNING: No build ID in response — ${BUILD_RESPONSE}"
    exit 0
fi

echo "[vrt-upload] Build created: ${BUILD_ID}"

# ── Step 2: Upload screenshots ────────────────────────────────

UPLOADED=0
FAILED=0

for png in "$VRT_SCREENSHOT_DIR"/*.png; do
    [ -f "$png" ] || continue

    # Derive test name from filename
    NAME=$(basename "$png" .png | tr '_' ' ' | tr '-' ' ')
    IMAGE_B64=$(base64 < "$png" | tr -d '\n')

    if ! curl -sf -X POST \
        "${VRT_API_URL}/test-runs" \
        -H "Content-Type: application/json" \
        -H "apiKey: ${VRT_API_KEY}" \
        -H "project: ${VRT_PROJECT}" \
        -d "{
            \"buildId\": \"${BUILD_ID}\",
            \"projectId\": \"${PROJECT_ID}\",
            \"branchName\": \"${VRT_BRANCH}\",
            \"name\": \"[${VRT_PLATFORM}] ${NAME}\",
            \"imageBase64\": \"${IMAGE_B64}\",
            \"os\": \"${VRT_PLATFORM}\",
            \"diffTollerancePercent\": ${VRT_DIFF_TOLERANCE}
        }" > /dev/null 2>&1; then
        echo "[vrt-upload]   WARN: Failed to upload $(basename "$png")"
        FAILED=$((FAILED + 1))
        continue
    fi

    UPLOADED=$((UPLOADED + 1))
done

# ── Step 3: Close build ───────────────────────────────────────

curl -sf -X PATCH \
    "${VRT_API_URL}/builds/${BUILD_ID}" \
    -H "Content-Type: application/json" \
    -H "apiKey: ${VRT_API_KEY}" \
    -H "project: ${VRT_PROJECT}" \
    -d '{}' >/dev/null 2>&1 || echo "[vrt-upload] WARNING: Failed to close build"

# ── Summary ───────────────────────────────────────────────────

echo "[vrt-upload] Done: $UPLOADED uploaded, $FAILED failed"
echo "[vrt-upload] Dashboard: ${VRT_API_URL}"
