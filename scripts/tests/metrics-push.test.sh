#!/usr/bin/env bash
# SPDX-FileCopyrightText: 2026 Mattia Egloff <mattia.egloff@pm.me>
#
# SPDX-License-Identifier: GPL-3.0-or-later
#
# Sentinel suite for scripts/ci/metrics-push.sh, run offline: curl is
# stubbed to answer every GitLab API call with an empty list.
#
# The payload must carry its own timestamp. It shares the Pushgateway group
# vauchi_engineering with _private's cycle metrics, so the group's
# push_time_seconds stayed fresh while this payload was answered HTTP 400
# from May to October 2026 and EngineeringMetricsStale never fired
# (private#470).

set -u

SCRIPT="$(cd "$(dirname "$0")/.." && pwd)/ci/metrics-push.sh"

pass=0
fail=0
check() {
    name="$1"; want="$2"; got="$3"
    if [ "$want" = "$got" ]; then
        pass=$((pass + 1)); printf '  PASS %s\n' "$name"
    else
        fail=$((fail + 1))
        printf '  FAIL %s\n    want: %s\n    got:  %s\n' "$name" "$want" "$got" >&2
    fi
}

work=$(mktemp -d)
mkdir -p "$work/bin"
# Every pipeline listing holds one pipeline; its job listing holds two
# failed jobs, so the per-job failure metric has two series per repository.
cat > "$work/bin/curl" <<'STUB'
#!/bin/sh
case "$*" in
    */jobs*) printf '[{"name":"test:unit","status":"failed","allow_failure":false},{"name":"lint:fmt","status":"failed","allow_failure":false}]\n200' ;;
    */pipelines*) printf '[{"id":1,"status":"failed","duration":60,"created_at":"2026-10-01T00:00:00Z","updated_at":"2026-10-01T00:01:00Z"}]\n200' ;;
    *) printf '[]\n200' ;;
esac
STUB
chmod +x "$work/bin/curl"

before=$(date +%s)
payload=$(PATH="$work/bin:$PATH" CI_JOB_TOKEN=stub bash "$SCRIPT" --ci --dry-run 2>/dev/null)
rc=$?
after=$(date +%s)

check "dry run exits 0" "0" "$rc"
check "the stubbed run still produces a payload" "1" \
    "$([ "$(printf '%s\n' "$payload" | grep -c .)" -gt 10 ] && echo 1 || echo 0)"

stamp=$(printf '%s\n' "$payload" | awk '$1 == "vauchi_eng_daily_push_timestamp_seconds" { print $2 }')
check "the payload carries exactly one timestamp line" "1" \
    "$(printf '%s\n' "$payload" | grep -c '^vauchi_eng_daily_push_timestamp_seconds ')"
check "the timestamp is the time of this run" "1" \
    "$([ -n "$stamp" ] && [ "$stamp" -ge "$before" ] && [ "$stamp" -le "$after" ] && echo 1 || echo 0)"

# The Pushgateway replaces a pushed `job` or `instance` label with the
# grouping key's, so series told apart only by such a label collapse into
# one and the whole payload is refused. That is what answered HTTP 400 from
# May to October 2026: the per-job failure metric carried the CI job's name
# in a label called `job` (scripts job 16885785551, 13 "was collected
# before with the same name and label values").
check "two failing jobs give two series for a repository" "2" \
    "$(printf '%s\n' "$payload" | grep -c '^vauchi_eng_ci_mr_job_failures_20{repo="core",')"
check "no pushed label is named job or instance" "" \
    "$(printf '%s\n' "$payload" | grep -E '[{,](job|instance)=' | head -3)"

# The Pushgateway rejects a payload that names one series twice.
check "no series appears twice" "" \
    "$(printf '%s\n' "$payload" | awk 'NF { print $1 }' | sort | uniq -d)"
check "every line is name, optional labels, numeric value" "" \
    "$(printf '%s\n' "$payload" | grep -vE '^[a-zA-Z_:][a-zA-Z0-9_:]*(\{[^}]*\})? -?[0-9.]+(e[-+]?[0-9]+)?$' | grep . | head -3)"

rm -rf "$work"

printf '\n%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
