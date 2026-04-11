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

# Validate min and warn are non-negative integers
if ! [[ "$MIN_VERSION" =~ ^[0-9]+$ ]]; then
    echo "Error: min must be a non-negative integer, got: $MIN_VERSION" >&2
    exit 1
fi
if ! [[ "$WARN_VERSION" =~ ^[0-9]+$ ]]; then
    echo "Error: warn must be a non-negative integer, got: $WARN_VERSION" >&2
    exit 1
fi

# Validate grace_deadline is ISO 8601 UTC if provided
if [ "$GRACE_DEADLINE" != "null" ]; then
    if ! [[ "$GRACE_DEADLINE" =~ ^[0-9]{4}-(0[1-9]|1[0-2])-(0[1-9]|[12][0-9]|3[01])T([01][0-9]|2[0-3]):[0-5][0-9]:[0-5][0-9]Z$ ]]; then
        echo "Error: grace_deadline must be ISO 8601 UTC (e.g. 2026-05-01T00:00:00Z), got: $GRACE_DEADLINE" >&2
        exit 1
    fi
    GRACE_DEADLINE="\"$GRACE_DEADLINE\""
fi

cat <<EOF
{
  "min_version": $MIN_VERSION,
  "warn_version": $WARN_VERSION,
  "grace_deadline": $GRACE_DEADLINE
}
EOF
