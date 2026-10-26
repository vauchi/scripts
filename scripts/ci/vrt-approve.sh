#!/bin/sh
# SPDX-FileCopyrightText: 2026 Mattia Egloff <mattia.egloff@pm.me>
#
# SPDX-License-Identifier: GPL-3.0-or-later
#
# Approve this pipeline's VRT build, making its screenshots the baseline
# (vauchi/private#836).
#
# vrt-upload.sh only uploads: VRT keeps new or changed images unresolved
# until an admin or editor approves them, and approval needs a user login,
# not the project API key. A dedicated recorder user does that here. Unlike
# the upload, this is not advisory: a deliberate record run fails loudly.
#
# Required environment:
#   VRT_RECORDER_EMAIL     — VRT user with the editor role
#   VRT_RECORDER_PASSWORD  — its password (protected, masked CI variable)
#   VRT_PLATFORM           — platform label the upload used (macos, ios, …)
#   CI_PIPELINE_ID         — the pipeline whose upload is approved
#
# Optional:
#   VRT_API_URL            — VRT instance (default: https://vrt.vauchi.app)
#   VRT_PROJECT            — project name (default: vauchi)
#
# API (Visual-Regression-Tracker backend):
#   POST  /users/login                 — {email,password} → {token}
#   GET   /projects                    — Bearer
#   GET   /builds?projectId&ciBuildId  — Bearer, paginated {data:[…]}
#   PATCH /builds/:id/approve?merge=   — Bearer, admin or editor

set -eu

VRT_API_URL="${VRT_API_URL:-https://vrt.vauchi.app}"
VRT_PROJECT="${VRT_PROJECT:-vauchi}"

fail() {
    echo "[vrt-approve] ERROR: $*" >&2
    exit 1
}

for var in VRT_RECORDER_EMAIL VRT_RECORDER_PASSWORD VRT_PLATFORM CI_PIPELINE_ID; do
    eval "value=\${$var:-}"
    [ -n "$value" ] || fail "$var is not set (a protected variable is only available on protected branches)"
done
command -v jq >/dev/null 2>&1 || fail "jq is not installed in this job's image"

CI_BUILD_ID="${CI_PIPELINE_ID}-${VRT_PLATFORM}"
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

# Prints the HTTP status; the body lands in $TMP/body. The status is read,
# not inferred from curl's exit (VSH13).
vrt_call() {
    method="$1" path="$2"
    shift 2
    : > "$TMP/body"
    curl -s -o "$TMP/body" -w '%{http_code}' --max-time 30 -X "$method" "$@" \
        "${VRT_API_URL}${path}" || echo 000
}

# ── Login ─────────────────────────────────────────────────────
jq -n --arg email "$VRT_RECORDER_EMAIL" --arg password "$VRT_RECORDER_PASSWORD" \
    '{email: $email, password: $password}' > "$TMP/login.json"
code=$(vrt_call POST /users/login -H "Content-Type: application/json" --data-binary "@$TMP/login.json")
rm -f "$TMP/login.json"
case "$code" in 2??) ;; *) fail "login as $VRT_RECORDER_EMAIL answered HTTP $code" ;; esac
TOKEN=$(jq -r '.token // empty' "$TMP/body")
[ -n "$TOKEN" ] || fail "login answered HTTP $code without a token"
AUTH="Authorization: Bearer $TOKEN"

# ── Project ───────────────────────────────────────────────────
code=$(vrt_call GET /projects -H "$AUTH")
case "$code" in 2??) ;; *) fail "listing projects answered HTTP $code" ;; esac
PROJECT_ID=$(jq -r --arg name "$VRT_PROJECT" '[.[] | select(.name == $name)][0].id // empty' "$TMP/body")
[ -n "$PROJECT_ID" ] || fail "VRT project '$VRT_PROJECT' not found"

# ── Build ─────────────────────────────────────────────────────
code=$(vrt_call GET "/builds?projectId=${PROJECT_ID}&ciBuildId=${CI_BUILD_ID}&take=10&skip=0" -H "$AUTH")
case "$code" in 2??) ;; *) fail "looking up build $CI_BUILD_ID answered HTTP $code" ;; esac
BUILD_ID=$(jq -r --arg id "$CI_BUILD_ID" '[.data[]? | select(.ciBuildId == $id)][0].id // empty' "$TMP/body")
[ -n "$BUILD_ID" ] || fail "no VRT build '$CI_BUILD_ID' — did test:screen-catalog upload in this pipeline?"

# ── Approve ───────────────────────────────────────────────────
code=$(vrt_call PATCH "/builds/${BUILD_ID}/approve?merge=false" -H "$AUTH")
case "$code" in 2??) ;; *) fail "approving build $CI_BUILD_ID answered HTTP $code (the recorder needs the editor role)" ;; esac

echo "[vrt-approve] Approved VRT build $CI_BUILD_ID ($BUILD_ID) as the $VRT_PLATFORM baseline"
