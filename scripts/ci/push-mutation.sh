#!/usr/bin/env bash
# SPDX-FileCopyrightText: 2026 Mattia Egloff <mattia.egloff@pm.me>
#
# SPDX-License-Identifier: GPL-3.0-or-later

# push-mutation.sh — Push mutation test metrics to Pushgateway
#
# Parses mutation testing output directory and pushes metrics to Prometheus
# Pushgateway via SSH. Designed to be called from CI mutation.yml jobs.
#
# Usage:
#   push-mutation.sh <mutants-output-dir> <repo-name>            # Push via SSH
#   push-mutation.sh <mutants-output-dir> <repo-name> --dry-run  # Print metrics only
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

MUTANTS_DIR="${1:-}"
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

if [ -z "$MUTANTS_DIR" ] || [ -z "$REPO_NAME" ]; then
    echo "ERROR: Usage: push-mutation.sh <mutants-output-dir> <repo-name> [--dry-run]" >&2
    exit 1
fi

if [ ! -d "$MUTANTS_DIR" ]; then
    echo "ERROR: Mutants output directory not found: $MUTANTS_DIR" >&2
    exit 1
fi

# ─── Parse Mutation Output ───────────────────────────────────────

# Count lines in each mutation category
CAUGHT=0
MISSED=0
TIMEOUT=0
UNVIABLE=0

[ -f "$MUTANTS_DIR/caught.txt" ] && CAUGHT=$(wc -l < "$MUTANTS_DIR/caught.txt" || echo 0)
[ -f "$MUTANTS_DIR/missed.txt" ] && MISSED=$(wc -l < "$MUTANTS_DIR/missed.txt" || echo 0)
[ -f "$MUTANTS_DIR/timeout.txt" ] && TIMEOUT=$(wc -l < "$MUTANTS_DIR/timeout.txt" || echo 0)
[ -f "$MUTANTS_DIR/unviable.txt" ] && UNVIABLE=$(wc -l < "$MUTANTS_DIR/unviable.txt" || echo 0)

# Calculate mutation score (caught / (caught + missed))
TOTAL=$((CAUGHT + MISSED))
if [ "$TOTAL" -gt 0 ]; then
    SCORE=$(awk "BEGIN { printf \"%.2f\", (100.0 * $CAUGHT / $TOTAL) }")
else
    SCORE="0.00"
fi

echo "push-mutation: ${REPO_NAME} — Score: ${SCORE}% (${CAUGHT}/${TOTAL} mutants)" >&2

# ─── Build Prometheus Metrics ────────────────────────────────────

METRICS_TEXT=""
METRICS_TEXT+="vauchi_eng_mutation_total{repo=\"${REPO_NAME}\"} ${TOTAL}"$'\n'
METRICS_TEXT+="vauchi_eng_mutation_caught{repo=\"${REPO_NAME}\"} ${CAUGHT}"$'\n'
METRICS_TEXT+="vauchi_eng_mutation_missed{repo=\"${REPO_NAME}\"} ${MISSED}"$'\n'
METRICS_TEXT+="vauchi_eng_mutation_timeout{repo=\"${REPO_NAME}\"} ${TIMEOUT}"$'\n'
METRICS_TEXT+="vauchi_eng_mutation_unviable{repo=\"${REPO_NAME}\"} ${UNVIABLE}"$'\n'
METRICS_TEXT+="vauchi_eng_mutation_score{repo=\"${REPO_NAME}\"} ${SCORE}"$'\n'

# ─── Push to Pushgateway ─────────────────────────────────────────

if $DRY_RUN; then
    echo "$METRICS_TEXT"
    exit 0
fi

# shellcheck source=setup-ssh-pushgateway.sh
source "$(dirname "$0")/setup-ssh-pushgateway.sh"
setup_ssh_pushgateway

if [ -n "${PUSHGATEWAY_URL:-}" ]; then
    echo "$METRICS_TEXT" | curl -s --data-binary @- \
        "${PUSHGATEWAY_URL}/metrics/job/vauchi_mutation/repo/${REPO_NAME}"
else
    # shellcheck disable=SC2029  # intentional client-side expansion of REPO_NAME
    echo "$METRICS_TEXT" | ssh "${PUSHGATEWAY_SSH_USER}@${PUSHGATEWAY_SSH_HOST}" \
        "curl -s --data-binary @- http://localhost:9091/metrics/job/vauchi_mutation/repo/${REPO_NAME}"
fi

echo "push-mutation: metrics pushed for ${REPO_NAME}" >&2
