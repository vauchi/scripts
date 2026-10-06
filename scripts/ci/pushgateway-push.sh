#!/usr/bin/env bash
# SPDX-FileCopyrightText: 2026 Mattia Egloff <mattia.egloff@pm.me>
# SPDX-License-Identifier: GPL-3.0-or-later

# pushgateway-push.sh — push metrics to the Pushgateway from CI.
#
# Source this file, then call pushgateway_push. It POSTs to
# $PUSHGATEWAY_URL (push.vauchi.app) with $PUSHGATEWAY_TOKEN as a bearer
# token and reports the HTTP status.
#
# There is no other transport. This file was setup-ssh-pushgateway.sh and
# fell back to the production deploy key, then a restricted key; those
# fallbacks hid a dead credential for four days (2026-08-01) and the
# restricted key was refused on every probe run from 2026-09-28
# (vauchi/private#15, #470). A push that fails now says so.

set -euo pipefail

# Push metrics to Pushgateway.
#
# Usage: pushgateway_push "$METRICS_TEXT" "/metrics/job/vauchi_foo/repo/bar"
#
# Returns 0 on success, 1 on failure (caller decides if fatal).
# Stamp the payload with the transport that is about to carry it, so a
# received metric says how it arrived.
#
# The stamp dates from the three-transport helper, where it recorded which
# one carried a metric; it stays so the existing series does not vanish.
_pushgateway_stamp() {
    printf '%s\nvauchi_push_transport{mode="%s"} 1\n' "$1" "$2"
}

# The Pushgateway says why it rejects a payload in the response body ("text
# format parsing error in line 3", "collected metric … was collected before
# with the same name and label values"). `curl --fail` discards that body
# and exits 22, which is how the engineering payload was answered HTTP 400
# from May to October 2026 with nobody able to say which line was wrong
# (private#470). So curl writes the body to stderr and the status to stdout,
# and the status decides.
_pushgateway_accepted() { # $1 = HTTP status, $2 = transport, $3 = exit code of the call
    case "$1" in
        2??) [ "$3" -eq 0 ] && return 0
             echo "pushgateway: unreachable via $2 (exit $3)" >&2 ;;
        ""|000) echo "pushgateway: unreachable via $2 (exit $3)" >&2 ;;
        # A refusal is reported by its status even when curl then exits
        # non-zero: the Pushgateway closed early while answering 400 and
        # curl exited 18 (scripts job 16885785551).
        *) echo "pushgateway: HTTP $1 via $2" >&2 ;;
    esac
    return 1
}

# POST stdin to the direct URL and print the HTTP status. push.vauchi.app
# takes "Authorization: Bearer $PUSHGATEWAY_TOKEN" (private#470); without the
# variable nothing is sent, as before.
#
# The header goes to curl through a config on a file descriptor rather than
# an argument: on a shared shell runner every job can read the others'
# command lines. A here-document on descriptor 3, not bash's <(…): jobs
# source this file from plain sh, where process substitution is a syntax
# error for the whole file.
_pushgateway_direct() { # $1 = URL
    local url="$1"
    if [ -z "${PUSHGATEWAY_TOKEN:-}" ]; then
        curl -sS -o /dev/stderr -w '%{http_code}' --connect-timeout 3 --max-time 5 \
            --data-binary @- "$url"
        return
    fi
    case "$PUSHGATEWAY_TOKEN" in
        *[!A-Za-z0-9_-]*)
            # It is written inside a quoted config value; never echo it.
            echo "pushgateway: PUSHGATEWAY_TOKEN holds characters outside A-Z a-z 0-9 _ - and was not sent" >&2
            return 1 ;;
    esac
    curl -sS -o /dev/stderr -w '%{http_code}' --connect-timeout 3 --max-time 5 \
        -K /dev/fd/3 --data-binary @- "$url" 3<<CONFIG
header = "Authorization: Bearer $PUSHGATEWAY_TOKEN"
CONFIG
}

pushgateway_push() {
    local metrics_text="$1"
    local url_path="$2"
    local http_status call_exit

    if [ -z "${PUSHGATEWAY_URL:-}" ]; then
        echo "pushgateway: PUSHGATEWAY_URL is not set; the metric was not delivered" >&2
        return 1
    fi
    http_status=$(_pushgateway_stamp "$metrics_text" direct |
        _pushgateway_direct "${PUSHGATEWAY_URL}${url_path}") && call_exit=0 || call_exit=$?
    if _pushgateway_accepted "$http_status" direct "$call_exit"; then
        echo "pushgateway: delivered via direct URL" >&2
        return 0
    fi
    # curl's stderr, which carries the Pushgateway's reason, is left in the
    # log on purpose: sent to /dev/null it hid six weeks of refusals
    # (private#15).
    echo "pushgateway: the metric was not delivered" >&2
    return 1
}
