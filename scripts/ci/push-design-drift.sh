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
#   push-design-drift.sh <repo-name> <implemented-count> <expected-count> <missing-list>
#   push-design-drift.sh <repo-name> <implemented-count> <expected-count> <missing-list> --dry-run
#
# Arguments:
#   repo-name          — Platform repo label (e.g. "linux-gtk", "android")
#   implemented-count  — Number of components the platform implements
#   expected-count     — Total component count from design specs
#   missing-list       — Comma-separated list of missing component names (or "none")
#
# Environment variables:
#   DEPLOY_SSH_PRIVATE_KEY  — Base64-encoded SSH private key (auto-set in CI)
#   PUSHGATEWAY_URL         — Override push target (default: SSH to VPS localhost:9091)

set -euo pipefail

# ─── Argument Parsing ────────────────────────────────────────────

REPO_NAME="${1:-}"
IMPLEMENTED="${2:-}"
EXPECTED="${3:-}"
MISSING_LIST="${4:-none}"
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
        "${PUSHGATEWAY_URL}/metrics/job/vauchi_design_drift/repo/${REPO_NAME}"
else
    # shellcheck disable=SC2029  # intentional client-side expansion of REPO_NAME
    echo "$METRICS_TEXT" | ssh vauchi@bold-hopper-vps \
        "curl -s --data-binary @- http://localhost:9091/metrics/job/vauchi_design_drift/repo/${REPO_NAME}"
fi

echo "push-design-drift: metrics pushed for ${REPO_NAME}" >&2
