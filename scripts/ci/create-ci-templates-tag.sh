#!/usr/bin/env bash
# SPDX-FileCopyrightText: 2026 Mattia Egloff <mattia.egloff@pm.me>
#
# SPDX-License-Identifier: GPL-3.0-or-later
#
# Creates the next ci-templates tag at CI_COMMIT_SHA (private#1068), for the
# manual tag:ci-templates job on scripts' main. The person who starts the job
# decides when templates ship; this script only names the tag and refuses a
# commit that already has one.
#
# Needs PROJECT_ACCESS_TOKEN (allowed to create protected tags), CI_API_V4_URL,
# CI_PROJECT_ID and CI_COMMIT_SHA. TAG_DATE (YYYY-MM-DD, default today in UTC)
# and CURL exist for the sentinel suite.

set -eu

: "${PROJECT_ACCESS_TOKEN:?PROJECT_ACCESS_TOKEN is required}"
: "${CI_API_V4_URL:?}" "${CI_PROJECT_ID:?}" "${CI_COMMIT_SHA:?}"
CURL="${CURL:-curl}"
TAG_DATE="${TAG_DATE:-$(date -u +%Y-%m-%d)}"
TAGS_URL="$CI_API_V4_URL/projects/$CI_PROJECT_ID/repository/tags"
HERE="$(cd "$(dirname "$0")" && pwd)"

body=$(mktemp)
pairs=$(mktemp)
trap 'rm -f "$body" "$pairs"' EXIT

# Every ci-templates tag as "name commit-sha", one per line.
page=1
while :; do
    status=$("$CURL" -sS -o "$body" -w '%{http_code}' \
        --header "PRIVATE-TOKEN: $PROJECT_ACCESS_TOKEN" \
        "$TAGS_URL?search=%5Eci-templates-v&per_page=100&page=$page") || status=000
    if [ "$status" != 200 ]; then
        echo "ERROR: listing tags: HTTP $status" >&2
        cat "$body" >&2
        exit 1
    fi
    count=$(python3 - "$body" "$pairs" <<'PY'
import json, sys
tags = json.load(open(sys.argv[1]))
with open(sys.argv[2], "a") as out:
    for tag in tags:
        if tag["name"].startswith("ci-templates-v"):
            out.write(f'{tag["name"]} {tag["commit"]["id"]}\n')
print(len(tags))
PY
)
    [ "$count" -eq 100 ] || break
    page=$((page + 1))
done

existing=$(awk -v sha="$CI_COMMIT_SHA" '$2 == sha { print $1 }' "$pairs")
if [ -n "$existing" ]; then
    echo "ERROR: $CI_COMMIT_SHA already carries $existing; nothing to tag." >&2
    exit 1
fi

tag=$(awk '{ print $1 }' "$pairs" | "$HERE/next-ci-templates-tag.sh" "$TAG_DATE")
status=$("$CURL" -sS -o "$body" -w '%{http_code}' -X POST \
    --header "PRIVATE-TOKEN: $PROJECT_ACCESS_TOKEN" \
    --data-urlencode "tag_name=$tag" \
    --data-urlencode "ref=$CI_COMMIT_SHA" \
    --data-urlencode "message=ci-templates release from $CI_COMMIT_SHA" \
    "$TAGS_URL") || status=000
if [ "$status" != 201 ]; then
    echo "ERROR: creating $tag: HTTP $status" >&2
    cat "$body" >&2
    exit 1
fi
echo "Created $tag at $CI_COMMIT_SHA."
echo "Consumers pick it up when their pins move to it (VSP01)."
