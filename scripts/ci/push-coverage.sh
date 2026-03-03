#!/usr/bin/env bash
# SPDX-FileCopyrightText: 2026 Mattia Egloff <mattia.egloff@pm.me>
#
# SPDX-License-Identifier: GPL-3.0-or-later

# push-coverage.sh — Push coverage metrics from Cobertura XML to Pushgateway
#
# Parses a Cobertura XML artifact and pushes coverage metrics to Prometheus
# Pushgateway via SSH. Designed to be called from individual CI coverage jobs.
#
# Usage:
#   push-coverage.sh <cobertura-xml> <repo-name>            # Push via SSH
#   push-coverage.sh <cobertura-xml> <repo-name> --dry-run  # Print metrics only
#
# Environment variables:
#   DEPLOY_SSH_PRIVATE_KEY  — Base64-encoded SSH private key (auto-set in CI)
#   PUSHGATEWAY_URL         — Override push target (default: SSH to VPS localhost:9091)

set -euo pipefail

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
    echo "ERROR: Usage: push-coverage.sh <cobertura-xml> <repo-name> [--dry-run]" >&2
    exit 1
fi

if [ ! -f "$COBERTURA_XML" ]; then
    echo "ERROR: Cobertura XML not found: $COBERTURA_XML" >&2
    exit 1
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

echo "push-coverage: ${REPO_NAME} — ${COVERAGE_PERCENT}% (${LINES_COVERED}/${LINES_VALID} lines)" >&2

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

# Set up SSH if DEPLOY_SSH_PRIVATE_KEY is available and key not already present
if [ -n "${DEPLOY_SSH_PRIVATE_KEY:-}" ] && [ ! -f ~/.ssh/id_ed25519 ]; then
    mkdir -p ~/.ssh
    base64 -d "$DEPLOY_SSH_PRIVATE_KEY" > ~/.ssh/id_ed25519
    chmod 600 ~/.ssh/id_ed25519
    cat >> ~/.ssh/config <<'SSHEOF'
Host bold-hopper-vps
  HostName 87.106.25.46
  User vauchi
  StrictHostKeyChecking accept-new
SSHEOF
    chmod 600 ~/.ssh/config
    trap 'rm -f ~/.ssh/id_ed25519' EXIT
fi

if [ -n "${PUSHGATEWAY_URL:-}" ]; then
    echo "$METRICS_TEXT" | curl -s --data-binary @- \
        "${PUSHGATEWAY_URL}/metrics/job/vauchi_coverage/repo/${REPO_NAME}"
else
    # shellcheck disable=SC2029  # intentional client-side expansion of REPO_NAME
    echo "$METRICS_TEXT" | ssh vauchi@bold-hopper-vps \
        "curl -s --data-binary @- http://localhost:9091/metrics/job/vauchi_coverage/repo/${REPO_NAME}"
fi

echo "push-coverage: metrics pushed for ${REPO_NAME}" >&2
