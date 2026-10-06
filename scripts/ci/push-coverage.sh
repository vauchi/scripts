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

# ─── Parse Cobertura XML ─────────────────────────────────────────

read -r LINE_RATE LINES_VALID LINES_COVERED <<< "$(python3 -c "
import xml.etree.ElementTree as ET, sys
try:
    tree = ET.parse('$COBERTURA_XML')
    root = tree.getroot()
    lr = float(root.attrib.get('line-rate', 0))
    lv = int(root.attrib.get('lines-valid', 0))
    lc = int(root.attrib.get('lines-covered', 0))
    print(f'{lr} {lv} {lc}')
except Exception as e:
    print(f'ERROR: {e}', file=sys.stderr)
    sys.exit(1)
")"

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
