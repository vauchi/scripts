#!/usr/bin/env bash
# SPDX-FileCopyrightText: 2026 Mattia Egloff <mattia.egloff@pm.me>
# SPDX-License-Identifier: GPL-3.0-or-later
#
# Generate the CDN version policy manifest (policy.json).
# Usage: generate-version-manifest.sh <min> <warn> [grace_deadline_iso]
#
# Examples:
#   generate-version-manifest.sh 1 1
#   generate-version-manifest.sh 1 2 2026-05-01T00:00:00Z

set -euo pipefail

MIN_VERSION="${1:?Usage: $0 <min> <warn> [grace_deadline_iso]}"
WARN_VERSION="${2:?Usage: $0 <min> <warn> [grace_deadline_iso]}"
GRACE_DEADLINE="${3:-null}"

if [ "$GRACE_DEADLINE" != "null" ]; then
    GRACE_DEADLINE="\"$GRACE_DEADLINE\""
fi

cat <<EOF
{
  "min_version": $MIN_VERSION,
  "warn_version": $WARN_VERSION,
  "grace_deadline": $GRACE_DEADLINE
}
EOF
