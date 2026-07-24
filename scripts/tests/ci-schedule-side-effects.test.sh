#!/bin/sh
# SPDX-FileCopyrightText: 2026 Mattia Egloff <mattia.egloff@pm.me>
#
# SPDX-License-Identifier: GPL-3.0-or-later

set -eu

failures=0

job_block() {
    file=$1
    job=$2
    awk -v job="$job" '
        $0 == job ":" { in_job = 1 }
        in_job && $0 != job ":" && /^[^[:space:]#]/ { exit }
        in_job { print }
    ' "$file"
}

require_schedule_guard() {
    file=$1
    job=$2
    block=$(job_block "$file" "$job")
    schedule_line=$(printf '%s\n' "$block" |
        grep -n 'CI_PIPELINE_SOURCE == "schedule"' |
        head -1 | cut -d: -f1 || true)
    default_line=$(printf '%s\n' "$block" |
        grep -n 'CI_COMMIT_BRANCH == \$CI_DEFAULT_BRANCH' |
        head -1 | cut -d: -f1 || true)

    if [ -n "$schedule_line" ] &&
        [ -n "$default_line" ] &&
        [ "$schedule_line" -lt "$default_line" ] &&
        printf '%s\n' "$block" |
        sed -n "${schedule_line},$((schedule_line + 1))p" |
        grep -q 'when: never'; then
        echo "PASS: $job excludes schedules before the default branch"
    else
        echo "FAIL: $job must exclude schedules before the default branch" >&2
        failures=$((failures + 1))
    fi
}

require_schedule_guard ci-templates/release.yml .auto-tag
require_schedule_guard ci-templates/github-mirror.yml .github-mirror
require_schedule_guard ci-templates/badges.yml .badges-pages

[ "$failures" -eq 0 ]
