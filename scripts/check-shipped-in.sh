#!/usr/bin/env bash
# SPDX-FileCopyrightText: 2026 Mattia Egloff <mattia.egloff@pm.me>
#
# SPDX-License-Identifier: GPL-3.0-or-later

# check-shipped-in.sh — VGT15: a commit that changes public text names the
# shipped work it describes (vauchi/private#1237).
# Page: _private/docs/lint-errors/vgt15-shipped-in-trailer.md
#
# Usage:
#   check-shipped-in.sh --staged <msg-file> [<repo-name>]
#       commit-msg hook: the staged paths against the message being written.
#   check-shipped-in.sh --range <base> <head> [<repo-name>]
#       CI: every commit in base..head; also resolves each cited MR (merged)
#       and sha (on that repo's main) through the GitLab API.
#
# The repo name defaults to the basename of the git top level. Public-text
# paths come from public-text-paths.txt beside this script.
# Env: SHIPPED_IN_API (default "glab api") runs an API GET; tests stub it.
#      GITLAB_GROUP (default "vauchi").
# Exit: 0 clean, 1 a violation, 2 the tool cannot decide (bad usage, no
#       path list, API unreachable in --range mode).

set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PATHS_FILE="$HERE/public-text-paths.txt"
PAGE="_private/docs/lint-errors/vgt15-shipped-in-trailer.md"
REF='[a-z0-9][a-z0-9_.-]*'
VALUE_RE="($REF!(0|[1-9][0-9]*)|$REF@[0-9a-f]{7,40}|roadmap|limit|correction $REF@[0-9a-f]{7,40}|n/a — (typo|link|formatting|translation))"

[ -f "$PATHS_FILE" ] || { echo "VGT15: no path list at $PATHS_FILE — cannot decide" >&2; exit 2; }

repo_name() {
    if [ -n "${1:-}" ]; then printf '%s' "$1"; return; fi
    basename "$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
}

public_re() { # $1=repo → the joined regex, empty when the repo has no public text
    if grep -qxE "!$1" "$PATHS_FILE"; then return 0; fi
    grep -vE '^(#|!|[[:space:]]*$)' "$PATHS_FILE" \
        | awk -v repo="$1" '($1 == "*" || $1 == repo) && $2 !~ /^!/ { print $2 }' \
        | paste -sd'|' -
}

public_exclusions() {
    awk -v repo="$1" '($1 == "*" || $1 == repo) && $2 ~ /^!/ { print substr($2, 2) }' "$PATHS_FILE" \
        | paste -sd'|' -
}

filter_public_paths() {
    VGT15_ALLOWED="$1" VGT15_EXCLUDED="$2" awk '
        BEGIN { allowed = ENVIRON["VGT15_ALLOWED"]; excluded = ENVIRON["VGT15_EXCLUDED"] }
        $0 ~ allowed && (excluded == "" || $0 !~ excluded)
    '
}

trailer_values() { # stdin: message → Shipped-in values, one per line
    grep -vE '^#' | grep -E '^Shipped-in:' | sed 's/^Shipped-in:[[:space:]]*//' || true
}

values_valid() { # $1=values (newline separated) → 0 when every one is valid and there is one
    [ -n "$1" ] || return 1
    while IFS= read -r v; do
        printf '%s\n' "$v" | grep -qxE "$VALUE_RE" || return 1
    done <<EOF
$1
EOF
}

report() { # $1=subject $2=paths
    echo ""
    echo "  VGT15: $(printf '%s' "$1" | cut -d: -f1) commit changes public text without a valid Shipped-in: trailer — fix: name the shipped work it describes, 'Shipped-in: <repo>!<MR>' or '<repo>@<sha>'; or 'roadmap', 'limit', 'correction <repo>@<sha>', or 'n/a — typo|link|formatting|translation'. Planned work goes on the roadmap, not in a page. [$PAGE]"
    echo ""
    echo "  Public text:"
    printf '%s\n' "$2" | sed 's/^/    /'
    echo ""
}

api_get() { # $1=path → body on stdout; non-zero when the call fails
    ${SHIPPED_IN_API:-glab api} "$1"
}

resolve() { # $1=value → 0 resolved, 1 refuted, 2 cannot tell
    local v="$1" ref repo target project body base
    case "$v" in
        roadmap|limit|n/a\ —\ *) return 0 ;;
        correction\ *) ref="${v#correction }" ;;
        *) ref="$v" ;;
    esac
    case "$ref" in
        *!*) repo="${ref%%!*}"; target="${ref#*!}" ;;
        *@*) repo="${ref%%@*}"; target="${ref#*@}" ;;
    esac
    # Public CI never reads the private tracker; a private reference is
    # checked for form only.
    case "$repo" in private|_private) return 0 ;; esac
    project="${GITLAB_GROUP:-vauchi}%2F$repo"
    if [ "$ref" != "${ref#*!}" ]; then
        body=$(api_get "projects/$project/merge_requests/$target") || return 2
        printf '%s' "$body" | grep -qE '"state": *"merged"' && return 0
        return 1
    fi
    # The merge base of a commit and main is the commit itself exactly when
    # it is on main. Listing the commit's branches is paginated, so main can
    # sit beyond the first page (private#1317).
    body=$(api_get "projects/$project/repository/merge_base?refs[]=$target&refs[]=main") || return 2
    base=$(printf '%s' "$body" | grep -oE '"id": *"[0-9a-f]{40}"' | head -n 1 | grep -oE '[0-9a-f]{40}')
    case "$base" in
        "$target"*) return 0 ;;
    esac
    return 1
}

check_message() { # $1=message $2=paths $3=resolve(0/1) → 0 ok, 1 violation, 2 cannot tell
    local msg="$1" paths="$2" do_resolve="$3" subject values v rc worst=0
    subject=$(printf '%s\n' "$msg" | head -n 1)
    printf '%s' "$subject" | grep -qE '^wip: ' && return 0
    [ -n "$paths" ] || return 0
    values=$(printf '%s\n' "$msg" | trailer_values)
    if ! values_valid "$values"; then
        report "$subject" "$paths"
        return 1
    fi
    [ "$do_resolve" = 1 ] || return 0
    while IFS= read -r v; do
        set +e; resolve "$v"; rc=$?; set -e
        if [ "$rc" = 1 ]; then
            echo "  VGT15: '$subject' cites '$v', which is not merged or not on main — fix: merge the work it describes first, or cite the change that shipped it. [$PAGE]"
            worst=1
        elif [ "$rc" = 2 ] && [ "$worst" = 0 ]; then
            echo "  VGT15: cannot resolve '$v' (API unreachable) — the check cannot decide." >&2
            worst=2
        fi
    done <<EOF
$values
EOF
    return "$worst"
}

mode="${1:-}"
case "$mode" in
    --staged)
        [ -n "${2:-}" ] || { echo "usage: check-shipped-in.sh --staged <msg-file> [<repo>]" >&2; exit 2; }
        repo=$(repo_name "${3:-}")
        re=$(public_re "$repo")
        [ -n "$re" ] || exit 0
        excluded=$(public_exclusions "$repo")
        if ! staged=$(git diff --cached --name-only); then
            echo "VGT15: cannot read the Git index; the check cannot decide." >&2
            exit 2
        fi
        paths=$(printf '%s\n' "$staged" | filter_public_paths "$re" "$excluded")
        check_message "$(cat "$2")" "$paths" 0
        ;;
    --range)
        [ -n "${2:-}" ] && [ -n "${3:-}" ] || { echo "usage: check-shipped-in.sh --range <base> <head> [<repo>]" >&2; exit 2; }
        repo=$(repo_name "${4:-}")
        re=$(public_re "$repo")
        [ -n "$re" ] || exit 0
        excluded=$(public_exclusions "$repo")
        if ! commits=$(git rev-list --no-merges "$2..$3"); then
            echo "VGT15: cannot read the Git range; the check cannot decide." >&2
            exit 2
        fi
        status=0
        for sha in $commits; do
            if ! changed=$(git diff-tree --no-commit-id --name-only -r "$sha"); then
                echo "VGT15: cannot read changed paths; the check cannot decide." >&2
                exit 2
            fi
            paths=$(printf '%s\n' "$changed" | filter_public_paths "$re" "$excluded")
            set +e; check_message "$(git log -1 --format=%B "$sha")" "$paths" 1; rc=$?; set -e
            if [ "$rc" = 1 ]; then status=1; elif [ "$rc" = 2 ] && [ "$status" = 0 ]; then status=2; fi
        done
        exit "$status"
        ;;
    *)
        echo "usage: check-shipped-in.sh --staged <msg-file> [<repo>] | --range <base> <head> [<repo>]" >&2
        exit 2
        ;;
esac
