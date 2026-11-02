#!/usr/bin/env bash
# SPDX-FileCopyrightText: 2026 Mattia Egloff <mattia.egloff@pm.me>
#
# SPDX-License-Identifier: GPL-3.0-or-later

# push-coverage.sh — Push coverage metrics from Cobertura XML to Pushgateway
#
# Parses a Cobertura XML artifact and pushes coverage metrics to Prometheus
# Pushgateway. Designed to be called from individual CI coverage jobs.
#
# Usage:
#   push-coverage.sh <cobertura-xml> <repo-name>            # Push
#   push-coverage.sh <cobertura-xml> <repo-name> --dry-run  # Print metrics only
#
# Environment variables:
#   PUSHGATEWAY_URL         — the push endpoint (push.vauchi.app)
#   PUSHGATEWAY_TOKEN       — its token, sent as a bearer

set -euo pipefail

# shellcheck source=../../lib/common.sh
source "$(dirname "${BASH_SOURCE[0]}")/../lib/common.sh"

# ─── Argument Parsing ────────────────────────────────────────────

COBERTURA_XML="${1:-}"
REPO_NAME="${2:-}"
DRY_RUN=false

for arg in "$@"; do
    case "$arg" in
        --dry-run) DRY_RUN=true ;;
        --help|-h)
            sed -n '6,/^$/p' "$0" | sed 's/^# //' | sed 's/^#//'
            exit 0
            ;;
    esac
done

if [ -z "$COBERTURA_XML" ] || [ -z "$REPO_NAME" ]; then
    die "Usage: push-coverage.sh <cobertura-xml> <repo-name> [--dry-run]"
fi

if [ ! -f "$COBERTURA_XML" ]; then
    die "Cobertura XML not found: $COBERTURA_XML"
fi

# ─── Parse the coverage report ───────────────────────────────────
# Cobertura (<coverage>) or JaCoCo (<report>, Android's Gradle plugin).
# Anything else, or a report counting no lines, fails: read as Cobertura, a
# JaCoCo report used to come out as 0/0 and push as a real 0% (private#1040).

PARSED=$(python3 - "$COBERTURA_XML" <<'PY'
import sys
import xml.etree.ElementTree as ET

try:
    root = ET.parse(sys.argv[1]).getroot()
    if root.tag == "coverage":
        lv = int(root.attrib.get("lines-valid", 0))
        lc = int(root.attrib.get("lines-covered", 0))
    elif root.tag == "report":
        line = next((c for c in root.findall("counter") if c.get("type") == "LINE"), None)
        if line is None:
            raise ValueError("JaCoCo report has no LINE counter")
        lc = int(line.get("covered"))
        lv = lc + int(line.get("missed"))
    else:
        raise ValueError(f"unknown coverage report root <{root.tag}>")
    if lv <= 0:
        raise ValueError("report counts no lines")
    print(f"{lc / lv} {lv} {lc}")
except Exception as e:
    print(f"ERROR: {e}", file=sys.stderr)
    sys.exit(1)
PY
) || die "cannot read coverage from $COBERTURA_XML"
read -r LINE_RATE LINES_VALID LINES_COVERED <<< "$PARSED"

COVERAGE_PERCENT=$(awk "BEGIN { printf \"%.2f\", $LINE_RATE * 100 }")

log_info "push-coverage: ${REPO_NAME} — ${COVERAGE_PERCENT}% (${LINES_COVERED}/${LINES_VALID} lines)"
# Print to stdout so GitLab coverage regex can capture it
echo "Line Coverage: ${COVERAGE_PERCENT}%"

# ─── Build Prometheus Metrics ────────────────────────────────────

METRICS_TEXT=""
METRICS_TEXT+="vauchi_eng_coverage_percent{repo=\"${REPO_NAME}\"} ${COVERAGE_PERCENT}"$'\n'
METRICS_TEXT+="vauchi_eng_coverage_lines_valid{repo=\"${REPO_NAME}\"} ${LINES_VALID}"$'\n'
METRICS_TEXT+="vauchi_eng_coverage_lines_covered{repo=\"${REPO_NAME}\"} ${LINES_COVERED}"$'\n'

# ─── Push to Pushgateway ─────────────────────────────────────────

if $DRY_RUN; then
    echo "$METRICS_TEXT"
    exit 0
fi

# shellcheck disable=SC1091  # dynamic source path — not resolvable without -x
source "$(dirname "$0")/pushgateway-push.sh"

if pushgateway_push "$METRICS_TEXT" "/metrics/job/vauchi_coverage/repo/${REPO_NAME}"; then
    log_success "push-coverage: metrics pushed for ${REPO_NAME}"
else
    log_warn "push-coverage: push failed for ${REPO_NAME} (non-fatal)"
fi
