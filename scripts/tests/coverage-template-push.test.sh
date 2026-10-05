#!/usr/bin/env bash
# SPDX-FileCopyrightText: 2026 Mattia Egloff <mattia.egloff@pm.me>
#
# SPDX-License-Identifier: GPL-3.0-or-later
#
# The coverage template fetches its scripts one file at a time. This suite
# lays out exactly the files the template fetches, at the paths it fetches
# them to, runs the command it runs, and expects the metrics to reach a
# stubbed Pushgateway. push-coverage.sh once sourced ../lib/common.sh, which
# the template never fetched; every coverage job died on that line and the
# template's `|| true` hid it, so no coverage reached Grafana (private#520).

set -u

ROOT=$(cd "$(dirname "$0")/../.." && pwd)
TEMPLATE="$ROOT/ci-templates/coverage.yml"

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
trap 'rm -rf "$work"' EXIT
project="$work/project"
mkdir -p "$project" "$work/bin"

# The template's fetch helper writes into existing directories only.
sed -n 's/^ *- mkdir -p \(.*\)$/\1/p' "$TEMPLATE" | while read -r dirs; do
    # shellcheck disable=SC2086  # the template's list of directories
    (cd "$project" && mkdir -p $dirs)
done

fetches=$(sed -n 's/^ *- fetch_vauchi_script \([^ ]*\) \([^ ]*\)$/\1 \2/p' "$TEMPLATE")
while read -r src dest; do
    [ -n "$src" ] || continue
    cp "$ROOT/$src" "$project/$dest"
    chmod +x "$project/$dest"
done <<EOF
$fetches
EOF

# shellcheck disable=SC2016  # matches the template's literal ${PROJECT_ROOT}
invocation=$(sed -n 's/^ *"\${PROJECT_ROOT}\/\([^"]*push-coverage\.sh\)".*/\1/p' "$TEMPLATE")
check "the template runs push-coverage.sh from the project root" \
    "1" "$(printf '%s\n' "$invocation" | grep -c .)"

cat > "$project/cobertura.xml" <<'XML'
<?xml version="1.0"?>
<coverage line-rate="0.5" lines-valid="200" lines-covered="100"></coverage>
XML

# Answers like the Pushgateway: status on stdout, the request body recorded.
cat > "$work/bin/curl" <<STUB
#!/bin/sh
for arg in "\$@"; do last="\$arg"; done
printf '%s\n' "\$last" > "$work/url"
cat > "$work/body"
printf '200'
STUB
chmod +x "$work/bin/curl"

PATH="$work/bin:$PATH" PUSHGATEWAY_URL="https://push.example" PUSHGATEWAY_TOKEN="" \
    DEPLOY_SSH_PRIVATE_KEY="" \
    "$project/$invocation" "$project/cobertura.xml" core > "$work/out" 2> "$work/err"
status=$?

check "push-coverage.sh runs from the fetched layout" "0" "$status"
check "the push goes to the coverage group of the repository" \
    "https://push.example/metrics/job/vauchi_coverage/repo/core" "$(cat "$work/url" 2>/dev/null)"
check "the pushed body carries the coverage percent" \
    'vauchi_eng_coverage_percent{repo="core"} 50.00' \
    "$(grep -F 'vauchi_eng_coverage_percent' "$work/body" 2>/dev/null)"

if [ "$fail" -ne 0 ]; then
    sed 's/^/    stderr: /' "$work/err" >&2
fi
echo "coverage-template-push: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
