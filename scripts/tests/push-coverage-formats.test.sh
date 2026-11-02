#!/usr/bin/env bash
# SPDX-FileCopyrightText: 2026 Mattia Egloff <mattia.egloff@pm.me>
#
# SPDX-License-Identifier: GPL-3.0-or-later
#
# push-coverage.sh reads a coverage report and prints the line coverage that
# GitLab's `coverage:` regex and Pushgateway take. Android hands it JaCoCo,
# not Cobertura; read as Cobertura, a JaCoCo report has no root attributes and
# came out as "0.00% (0/0 lines)", which would push as a real 0%
# (private#1040). Every report must give its true figure or fail.

set -u

ROOT=$(cd "$(dirname "$0")/../.." && pwd)
PUSH="$ROOT/scripts/ci/push-coverage.sh"

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

# Prints "<exit> <Line Coverage line or ->" for one report.
run() {
    out=$("$PUSH" "$1" demo --dry-run 2>/dev/null)
    status=$?
    line=$(printf '%s\n' "$out" | grep '^Line Coverage:' || true)
    printf '%s %s' "$status" "${line:--}"
}

cat > "$work/cobertura.xml" <<'XML'
<?xml version="1.0" ?>
<coverage line-rate="0.5" lines-valid="4" lines-covered="2" version="1"></coverage>
XML
check "cobertura reports its line rate" \
    "0 Line Coverage: 50.00%" "$(run "$work/cobertura.xml")"

cat > "$work/jacoco.xml" <<'XML'
<?xml version="1.0" encoding="UTF-8" standalone="yes"?>
<report name="app">
  <counter type="INSTRUCTION" missed="90" covered="10"/>
  <counter type="LINE" missed="3" covered="1"/>
</report>
XML
check "jacoco reports its LINE counter" \
    "0 Line Coverage: 25.00%" "$(run "$work/jacoco.xml")"

cat > "$work/jacoco-no-lines.xml" <<'XML'
<?xml version="1.0" encoding="UTF-8" standalone="yes"?>
<report name="app"><counter type="INSTRUCTION" missed="9" covered="1"/></report>
XML
check "jacoco without a LINE counter fails" \
    "1 -" "$(run "$work/jacoco-no-lines.xml")"

printf '<?xml version="1.0" ?>\n<unknown/>\n' > "$work/unknown.xml"
check "an unknown report format fails" \
    "1 -" "$(run "$work/unknown.xml")"

cat > "$work/empty.xml" <<'XML'
<?xml version="1.0" ?>
<coverage line-rate="0" lines-valid="0" lines-covered="0" version="1"></coverage>
XML
check "a report that counts no lines fails" \
    "1 -" "$(run "$work/empty.xml")"

if [ "$fail" -ne 0 ]; then
    echo "push-coverage-formats: $pass passed, $fail failed" >&2
    exit 1
fi
echo "push-coverage-formats: $pass passed, $fail failed"
