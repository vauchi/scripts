#!/usr/bin/env bash
# SPDX-FileCopyrightText: 2026 Mattia Egloff <mattia.egloff@pm.me>
#
# SPDX-License-Identifier: GPL-3.0-or-later

# check-spec-trailer.sh — VGT12: a behaviour change on a protocol path says
# what it means for the spec (vauchi/private#874, #950).
# Page: _private/docs/lint-errors/vgt12-spec-trailer.md
#
# Usage:
#   check-spec-trailer.sh --staged <msg-file> [<repo-name>]
#       commit-msg hook: the staged paths against the message being written.
#   check-spec-trailer.sh --range <base> <head> [<repo-name>]
#       CI: every commit in base..head.
#
# The repo name defaults to the basename of the git top level; the relays
# are told from Core by it.
# Exit: 0 clean, 1 a violation, 2 the tool cannot decide (bad usage, git
#       cannot read the index or the range).

set -euo pipefail

PAGE="_private/docs/lint-errors/vgt12-spec-trailer.md"

repo_name() {
    if [ -n "${1:-}" ]; then printf '%s' "$1"; return; fi
    basename "$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
}

protocol_re() { # $1=repo
    case "$1" in
        relay|ohttp-relay) printf '%s' '^src/' ;;
        *) printf '%s' '^(vauchi-core/src/(crypto|exchange|network|backup|recovery|sync)/|vauchi-core/verification/|vauchi-protocol/src/)' ;;
    esac
}

filter_protocol_paths() { # $1=regex; stdin: paths
    grep -E "$1" | grep -vE '\.md$' || true
}

report() { # $1=subject $2=paths $3=heading for the paths
    echo ""
    echo "  VGT12: $(printf '%s' "$1" | cut -d: -f1) commit touches a protocol path without a Spec: trailer — fix: end the message with 'Spec: unchanged' if the spec's claims and chapters still describe the code, or 'Spec: <claim ids, chapter sections, spec!N>' naming what this moves. [$PAGE]"
    echo ""
    echo "  $3"
    printf '%s\n' "$2" | sed 's/^/    /'
    echo ""
    echo "  Example trailers:"
    echo "    Spec: unchanged"
    echo "    Spec: S4, relay B5, update-and-sync C1 (spec!9)"
    echo ""
}

check_message() { # $1=message $2=protocol paths $3=heading → 0 ok, 1 violation
    local subject
    subject=$(printf '%s\n' "$1" | head -n 1)
    printf '%s' "$subject" | grep -qE '^(feat|fix|refactor): ' || return 0
    [ -n "$2" ] || return 0
    if printf '%s\n' "$1" | grep -vE '^#' | grep -qE '^Spec: [^[:space:]]'; then
        return 0
    fi
    report "$subject" "$2" "$3"
    return 1
}

mode="${1:-}"
case "$mode" in
    --staged)
        [ -n "${2:-}" ] || { echo "usage: check-spec-trailer.sh --staged <msg-file> [<repo>]" >&2; exit 2; }
        if ! staged=$(git diff --cached --name-only); then
            echo "VGT12: cannot read the Git index; the check cannot decide." >&2
            exit 2
        fi
        re=$(protocol_re "$(repo_name "${3:-}")")
        paths=$(printf '%s\n' "$staged" | filter_protocol_paths "$re")
        check_message "$(cat "$2")" "$paths" "Protocol paths staged:"
        ;;
    --range)
        [ -n "${2:-}" ] && [ -n "${3:-}" ] || { echo "usage: check-spec-trailer.sh --range <base> <head> [<repo>]" >&2; exit 2; }
        if ! commits=$(git rev-list --no-merges "$2..$3"); then
            echo "VGT12: cannot read the Git range; the check cannot decide." >&2
            exit 2
        fi
        re=$(protocol_re "$(repo_name "${4:-}")")
        status=0
        for sha in $commits; do
            if ! changed=$(git diff-tree --no-commit-id --name-only -r "$sha"); then
                echo "VGT12: cannot read changed paths; the check cannot decide." >&2
                exit 2
            fi
            paths=$(printf '%s\n' "$changed" | filter_protocol_paths "$re")
            message=$(git log -1 --format=%B "$sha")
            if ! check_message "$message" "$paths" "Protocol paths in $(git rev-parse --short "$sha") ($(printf '%s\n' "$message" | head -n 1)):"; then
                echo "  The commit is already made: reword it with the trailer (git commit --amend, or git rebase for an older one) and push the branch again."
                echo ""
                status=1
            fi
        done
        exit "$status"
        ;;
    *)
        echo "usage: check-spec-trailer.sh --staged <msg-file> [<repo>] | --range <base> <head> [<repo>]" >&2
        exit 2
        ;;
esac
