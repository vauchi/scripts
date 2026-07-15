#!/usr/bin/env bash
# SPDX-FileCopyrightText: 2026 Mattia Egloff <mattia.egloff@pm.me>
# SPDX-License-Identifier: GPL-3.0-or-later

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")/../.." && pwd)"
CHECKER="$SCRIPT_DIR/scripts/ci/check-sast-severity.py"
TEMPLATE="$SCRIPT_DIR/ci-templates/security.yml"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

pass=0
fail=0

assert_status() {
    name="$1"
    expected="$2"
    report="$3"

    set +e
    output="$(python3 "$CHECKER" "$report" 2>&1)"
    actual=$?
    set -e

    if [[ "$actual" -eq "$expected" ]]; then
        pass=$((pass + 1))
        printf '  PASS %s\n' "$name"
    else
        fail=$((fail + 1))
        printf '  FAIL %s\n    expected status: %s\n    actual status:   %s\n    output: %s\n' \
            "$name" "$expected" "$actual" "$output" >&2
    fi
}

assert_contains() {
    name="$1"
    pattern="$2"
    file="$3"

    if grep -Eq "$pattern" "$file"; then
        pass=$((pass + 1))
        printf '  PASS %s\n' "$name"
    else
        fail=$((fail + 1))
        printf '  FAIL %s\n    missing pattern: %s\n' "$name" "$pattern" >&2
    fi
}

cat > "$WORK/clean.json" <<'EOF'
{"version":"15.0.7","vulnerabilities":[],"scan":{}}
EOF

cat > "$WORK/medium.json" <<'EOF'
{"version":"15.0.7","vulnerabilities":[{"id":"MED-1","name":"medium finding","severity":"Medium"}],"scan":{}}
EOF

cat > "$WORK/high.json" <<'EOF'
{"version":"15.0.7","vulnerabilities":[{"id":"HIGH-1","name":"high finding","severity":"High"}],"scan":{}}
EOF

cat > "$WORK/critical.json" <<'EOF'
{"version":"15.0.7","vulnerabilities":[{"id":"CRIT-1","name":"critical finding","severity":"Critical"}],"scan":{}}
EOF

cat > "$WORK/malformed.json" <<'EOF'
{"version":"15.0.7","vulnerabilities":
EOF

cat > "$WORK/missing-vulnerabilities.json" <<'EOF'
{"version":"15.0.7","scan":{}}
EOF

cat > "$WORK/malformed-finding.json" <<'EOF'
{"version":"15.0.7","vulnerabilities":[{"id":"NO-SEVERITY"}],"scan":{}}
EOF

assert_status "clean report passes" 0 "$WORK/clean.json"
assert_status "medium finding remains advisory" 0 "$WORK/medium.json"
assert_status "high finding remains advisory" 0 "$WORK/high.json"
assert_status "critical finding blocks" 1 "$WORK/critical.json"
assert_status "missing report fails closed" 2 "$WORK/missing.json"
assert_status "invalid JSON fails closed" 2 "$WORK/malformed.json"
assert_status "missing vulnerability list fails closed" 2 "$WORK/missing-vulnerabilities.json"
assert_status "finding without severity fails closed" 2 "$WORK/malformed-finding.json"
assert_contains "shared template exposes severity gate" '^\.security-sast-severity-gate:' "$TEMPLATE"
assert_contains "severity gate consumes semgrep report artifacts" 'job: semgrep-sast' "$TEMPLATE"
assert_contains "severity gate is blocking" 'allow_failure: false' "$TEMPLATE"
assert_contains "severity gate runs the checked validator" 'check-sast-severity.py gl-sast-report.json' "$TEMPLATE"

printf '\ncheck-sast-severity.test: %d passed, %d failed\n' "$pass" "$fail"
[[ "$fail" -eq 0 ]]
