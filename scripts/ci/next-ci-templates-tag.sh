#!/usr/bin/env bash
# SPDX-FileCopyrightText: 2026 Mattia Egloff <mattia.egloff@pm.me>
#
# SPDX-License-Identifier: GPL-3.0-or-later
#
# Prints the next ci-templates tag. Usage:
#   next-ci-templates-tag.sh YYYY-MM-DD < existing-tag-names
#
# Tags are dated, ci-templates-vYYYY.MM.DD. When today's is taken, or the
# month already has a later one, the next is one past the month's highest,
# so the tags keep sorting in release order (`sort -V`, VSP01's window).

set -eu

today="${1:-}"
case "$today" in
    [0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]) ;;
    *)
        echo "next-ci-templates-tag: expected YYYY-MM-DD, got '$today'" >&2
        exit 1
        ;;
esac
year="${today%%-*}"
rest="${today#*-}"
month="${rest%%-*}"
day="${rest#*-}"

prefix="ci-templates-v$year.$month."
highest=$(grep -E "^ci-templates-v$year\.$month\.[0-9]+$" | sed "s/^ci-templates-v$year\.$month\.//" \
    | sort -n | tail -1 || true)

# A leading zero would make "08" octal in shell arithmetic.
next="${day#0}"
highest="${highest#0}"
if [ -n "$highest" ] && [ "$next" -le "$highest" ]; then
    next=$((highest + 1))
fi
printf '%s%02d\n' "$prefix" "$next"
