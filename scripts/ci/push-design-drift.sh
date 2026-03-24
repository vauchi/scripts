#!/usr/bin/env bash
# SPDX-FileCopyrightText: 2026 Mattia Egloff <mattia.egloff@pm.me>
#
# SPDX-License-Identifier: GPL-3.0-or-later

# push-design-drift.sh — Push design drift metrics to Pushgateway
#
# Compares a platform repo's component renderer files against the design
# spec component list and pushes coverage metrics to Prometheus Pushgateway.
#
# Usage:
#   push-design-drift.sh <repo-name> <implemented-count> <expected-count>
#   push-design-drift.sh <repo-name> <implemented-count> <expected-count> --dry-run
#
# Arguments:
#   repo-name          — Platform repo label (e.g. "linux-gtk", "android")
#   implemented-count  — Number of components the platform implements
#   expected-count     — Total component count from design specs
#
# Environment variables:
#   DEPLOY_SSH_PRIVATE_KEY  — Base64-encoded SSH private key (auto-set in CI)
#   PUSHGATEWAY_URL         — Override push target (default: SSH to VPS localhost:9091)

set -euo pipefail

# ─── Pushgateway SSH target ─────────────────────────────────────
# Override via group-level CI variables to change the VPS
PUSHGATEWAY_SSH_HOST="${PUSHGATEWAY_SSH_HOST:-bold-hopper-vps}"
PUSHGATEWAY_SSH_IP="${PUSHGATEWAY_SSH_IP:-87.106.25.46}"
PUSHGATEWAY_SSH_USER="${PUSHGATEWAY_SSH_USER:-vauchi}"

# ─── Argument Parsing ────────────────────────────────────────────

REPO_NAME="${1:-}"
IMPLEMENTED="${2:-}"
EXPECTED="${3:-}"
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

if [ -z "$REPO_NAME" ] || [ -z "$IMPLEMENTED" ] || [ -z "$EXPECTED" ]; then
    echo "ERROR: Usage: push-design-drift.sh <repo-name> <implemented> <expected> [missing-list] [--dry-run]" >&2
    exit 1
fi

# ─── Calculate Score ─────────────────────────────────────────────

MISSING=$((EXPECTED - IMPLEMENTED))
if [ "$EXPECTED" -gt 0 ]; then
    SCORE=$(awk "BEGIN { printf \"%.2f\", (100.0 * $IMPLEMENTED / $EXPECTED) }")
else
    SCORE="100.00"
fi

echo "push-design-drift: ${REPO_NAME} — ${SCORE}% (${IMPLEMENTED}/${EXPECTED} components, ${MISSING} missing)" >&2

# ─── Build Prometheus Metrics ────────────────────────────────────

METRICS_TEXT=""
METRICS_TEXT+="vauchi_eng_design_drift_expected{repo=\"${REPO_NAME}\"} ${EXPECTED}"$'\n'
METRICS_TEXT+="vauchi_eng_design_drift_implemented{repo=\"${REPO_NAME}\"} ${IMPLEMENTED}"$'\n'
METRICS_TEXT+="vauchi_eng_design_drift_missing{repo=\"${REPO_NAME}\"} ${MISSING}"$'\n'
METRICS_TEXT+="vauchi_eng_design_drift_score{repo=\"${REPO_NAME}\"} ${SCORE}"$'\n'

# ─── Push to Pushgateway ─────────────────────────────────────────

if $DRY_RUN; then
    echo "$METRICS_TEXT"
    exit 0
fi

# shellcheck disable=SC1091  # dynamic source path — not resolvable without -x
source "$(dirname "$0")/setup-ssh-pushgateway.sh"
setup_ssh_pushgateway

if [ -n "${PUSHGATEWAY_URL:-}" ]; then
    echo "$METRICS_TEXT" | curl -s --data-binary @- \
        "${PUSHGATEWAY_URL}/metrics/job/vauchi_design_drift/repo/${REPO_NAME}"
else
    # shellcheck disable=SC2029  # intentional client-side expansion of REPO_NAME
    echo "$METRICS_TEXT" | ssh "${PUSHGATEWAY_SSH_USER}@${PUSHGATEWAY_SSH_HOST}" \
        "curl -s --data-binary @- http://localhost:9091/metrics/job/vauchi_design_drift/repo/${REPO_NAME}"
fi

echo "push-design-drift: metrics pushed for ${REPO_NAME}" >&2
