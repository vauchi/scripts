#!/bin/sh
# SPDX-FileCopyrightText: 2026 Mattia Egloff <mattia.egloff@pm.me>
#
# SPDX-License-Identifier: GPL-3.0-or-later
#
# Fails when an MR author has not signed the Contributor License
# Agreement, i.e. has no row in docs/src/developers/cla-signatures.md.
#
# Usage: check-cla.sh <cla-signatures.md> <gitlab-username>
#
# Exempt: the accounts in CLA_EXEMPT (space-separated, default: the
# maintainer, who is the Licensor and does not sign) and the vauchi
# group's access-token bots (CLA_BOT_PREFIX), which only maintainers can
# create.
#
# Exit: 0 signed or exempt, 1 not signed, 2 unusable input. A list that
# does not contain the signature table is exit 2, never a pass: a login
# page or an error body must not read as "nobody is unsigned".
#
# Portability: POSIX shell only (runs in alpine CI).
set -eu

CLA_URL="https://vauchi.app/docs/developers/cla.html"

list="${1:-}"
author=$(printf '%s' "${2:-}" | sed 's/^@//' | tr '[:upper:]' '[:lower:]')

if [ -z "$author" ]; then
    echo "check-cla: no MR author given" >&2
    exit 2
fi
if [ ! -f "$list" ]; then
    echo "check-cla: signature list not found: $list" >&2
    exit 2
fi
if ! grep -qi '^| *name *| *gitlab account *|' "$list"; then
    echo "check-cla: $list has no signature table — refusing to pass" >&2
    exit 2
fi

for exempt in ${CLA_EXEMPT-megloff1}; do
    if [ "$author" = "$(printf '%s' "$exempt" | tr '[:upper:]' '[:lower:]')" ]; then
        echo "check-cla: @$author is the maintainer — exempt"
        exit 0
    fi
done
# Only this group's tokens: the public API has no bot flag, so a looser
# pattern would exempt anyone who registers a bot-shaped username.
bot_prefix="${CLA_BOT_PREFIX-group_122552022_bot_}"
if [ -n "$bot_prefix" ] && printf '%s' "$author" | grep -Eq "^${bot_prefix}[0-9a-f]+\$"; then
    echo "check-cla: @$author is an access-token bot — exempt"
    exit 0
fi

signed=$(awk -F'|' -v want="$author" '
    /^\|/ {
        account = tolower($3)
        gsub(/[ \t@]/, "", account)
        if (account == want) { print "yes"; exit }
    }' "$list")

if [ "$signed" = "yes" ]; then
    echo "check-cla: @$author has signed the CLA"
    exit 0
fi

cat >&2 <<EOF
check-cla: @$author has not signed the Vauchi Contributor License Agreement.

Before this merge request can be merged, please read the agreement and
sign it once by adding yourself to the signature list:
  $CLA_URL  (see "How to sign")
EOF
exit 1
