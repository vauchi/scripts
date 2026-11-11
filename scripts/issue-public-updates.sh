#!/usr/bin/env bash
# SPDX-FileCopyrightText: 2026 Mattia Egloff <mattia.egloff@pm.me>
#
# SPDX-License-Identifier: GPL-3.0-or-later

# issue-public-updates.sh — print an issue description that ends with the
# "Public updates once done and tested" section, adding it when absent.
#
# Public text (docs, website, spec, feature tags, READMEs) changes only
# after the work is done and tested (owner decision 2026-11-11,
# vauchi/private#1229); the section is where an issue lists that text.
#
# Usage: issue-public-updates.sh <description>

set -euo pipefail

if [ "$#" -ne 1 ]; then
    echo "usage: issue-public-updates.sh <description>" >&2
    exit 2
fi

description="$1"
heading='## Public updates once done and tested'

if printf '%s\n' "$description" | grep -qx "$heading"; then
    printf '%s' "$description"
    exit 0
fi

section="$heading

- [ ] none yet: list each public page, spec line, feature tag or README
  that changes when this ships. Change them only after the work is done
  and its test or rig run passed, citing that evidence."

if [ -z "$description" ]; then
    printf '%s' "$section"
else
    printf '%s\n\n%s' "$description" "$section"
fi
