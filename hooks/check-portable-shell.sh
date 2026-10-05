#!/usr/bin/env bash
# SPDX-FileCopyrightText: 2026 Mattia Egloff <mattia.egloff@pm.me>
# SPDX-License-Identifier: GPL-3.0-or-later
#
# Portable shell linter — catches GNU-vs-BSD patterns that shellcheck misses.
# Called by: pre-commit hook (staged .sh and .just files)
# Also runnable standalone: ./check-portable-shell.sh [file ...]
#
# Complements shellcheck (which catches shell-language bashisms) with checks
# for external-command portability (grep -P, \s in sed, echo -e, etc.).
# See: .claude/rules/portable-shell.md

set -euo pipefail

VIOLATIONS=0
CHECKED=0

# emit <id> <file> <line_no> <what> <fix> <page-slug>
# One line per violation: ID, location, problem, imperative fix, page.
emit() {
    printf '  %s:%s: %s: %s — fix: %s. [_private/docs/lint-errors/%s.md]\n' \
        "$2" "$3" "$1" "$4" "$5" "$6"
}

check_file() {
    local file="$1"
    local line_no=0 read_no=0 start_no=0 logical=""
    local found=0

    while IFS= read -r line; do
        read_no=$((read_no + 1))

        # Skip comments and empty lines
        [[ "$line" =~ ^[[:space:]]*# ]] && continue
        [[ -z "$line" ]] && continue

        # Check a backslash-continued command as one line, reported at its
        # first line: otherwise a flag on a continuation line never meets
        # its command (`find … \` then `-printf …`, vauchi/private#521).
        [[ -z "$logical" ]] && start_no="$read_no"
        logical+="${line%\\} "
        [[ "$line" == *\\ ]] && continue
        line="$logical"
        logical=""
        line_no="$start_no"

        # Skip lines with inline suppression, string literals, or regex tests.
        # Use "# portable-shell-ok" to suppress false positives on specific lines.
        # shellcheck disable=SC2016
        if [[ "$line" =~ portable-shell-ok ]] \
            || [[ "$line" =~ ^[[:space:]]*[\'\"] ]] \
            || [[ "$line" =~ '=~' ]]; then
            continue
        fi

        # VSH01 grep -P (GNU Perl regex — absent on BSD/BusyBox grep)
        if [[ "$line" =~ grep[[:space:]]+-[a-zA-Z]*P ]]; then
            emit VSH01 "$file" "$line_no" 'grep -P is GNU-only (BSD/BusyBox lack it)' 'use grep -E, just grep (ripgrep), or sed -n extraction' vsh01-grep-perl-regex # portable-shell-ok
            found=1
        fi

        # VSH02 echo -e (non-POSIX — behavior varies across shells)
        if [[ "$line" =~ echo[[:space:]]+-e[[:space:]] ]]; then
            emit VSH02 "$file" "$line_no" 'echo -e is non-POSIX (escape handling varies)' 'use printf (%b for escape expansion)' vsh02-echo-dash-e # portable-shell-ok
            found=1
        fi

        # VSH03 \s in grep/sed/awk (PCRE class — BSD/BusyBox match literal s)
        if [[ "$line" =~ \\s ]] && [[ "$line" =~ (grep|sed|awk) ]]; then
            # Exclude Python raw strings, jq, and inline-disable comments
            if [[ ! "$line" =~ (r\'|r\"|python|\\.jq|portable-shell-ok) ]]; then
                emit VSH03 "$file" "$line_no" '\s in grep/sed/awk is non-POSIX (silently wrong on BSD)' 'use [[:space:]]' vsh03-backslash-s-class # portable-shell-ok
                found=1
            fi
        fi

        # VSH04 readlink -f (GNU-only — macOS BSD readlink has no -f)
        if [[ "$line" =~ readlink[[:space:]]+-f ]]; then
            emit VSH04 "$file" "$line_no" 'readlink -f is GNU-only (fails on macOS)' 'use realpath or cd+pwd resolution' vsh04-readlink-f # portable-shell-ok
            found=1
        fi

        # VSH05 stat -c (GNU format flag — macOS uses stat -f)
        if [[ "$line" =~ stat[[:space:]]+-c ]]; then
            # Allow if there's a fallback on the same line
            if [[ ! "$line" =~ stat[[:space:]]+-f ]]; then
                emit VSH05 "$file" "$line_no" 'stat -c is GNU-only with no BSD fallback' 'pair it: stat -c ... 2>/dev/null || stat -f ...' vsh05-stat-c # portable-shell-ok
                found=1
            fi
        fi

        # VSH06 grep --exclude/--include (GNU long options — BusyBox grep
        # ignores or rejects them; caused the 2026-04 lint:claude-md
        # every-doc-is-orphan incident)
        if [[ "$line" =~ grep[[:space:]].*--(exclude|include) ]]; then
            emit VSH06 "$file" "$line_no" 'grep --exclude/--include is GNU-only (BusyBox CI ignores it)' 'use find|xargs grep or a grep -v post-filter' vsh06-grep-exclude # portable-shell-ok
            found=1
        fi

        # VSH07 sed in-place: --in-place is GNU-only; -i '' is BSD-only
        if [[ "$line" =~ sed[[:space:]].*--in-place ]] \
            || [[ "$line" == *"sed -i ''"* ]] || [[ "$line" == *'sed -i ""'* ]]; then # portable-shell-ok
            emit VSH07 "$file" "$line_no" 'non-portable sed in-place form (GNU/BSD/BusyBox disagree)' "use sed -i.bak ... && rm ...bak" vsh07-sed-in-place # portable-shell-ok
            found=1
        fi

        # VSH08 find -printf (GNU findutils — absent on BSD/BusyBox find)
        if [[ "$line" =~ find[[:space:]].*-printf ]]; then
            emit VSH08 "$file" "$line_no" 'find -printf is GNU-only' 'use find -exec <cmd> {} \; or -print0|xargs -0' vsh08-find-printf # portable-shell-ok
            found=1
        fi

        # VSH09 awk gensub() (gawk-only — BusyBox/one-true-awk lack it)
        if [[ "$line" =~ gensub\( ]] && [[ "$line" =~ awk ]]; then
            emit VSH09 "$file" "$line_no" 'awk gensub() is gawk-only' 'use POSIX sub()/gsub() with an intermediate variable' vsh09-awk-gensub # portable-shell-ok
            found=1
        fi

        # VSH10 date -d/--date (GNU parsing — BSD date -d sets DST flag!)
        if [[ "$line" =~ date[[:space:]]+(-d|--date)[[:space:]] ]]; then
            emit VSH10 "$file" "$line_no" 'date -d is GNU-only (BSD does something else silently)' 'use epoch math (date +%s) or platform-switched date -j -f' vsh10-date-d # portable-shell-ok
            found=1
        fi

        # VSH11 md5sum (not on macOS; md5 there — prefer shasum anyway)
        if [[ "$line" =~ md5sum ]]; then
            emit VSH11 "$file" "$line_no" 'md5sum does not exist on macOS' 'use shasum -a 256' vsh11-md5sum # portable-shell-ok
            found=1
        fi

        # VSH12 GNU \+ in sed basic regex (BSD sed matches a literal +)
        if [[ "$line" == *sed* ]] && [[ "$line" == *'\+'* ]]; then # portable-shell-ok
            emit VSH12 "$file" "$line_no" 'GNU \+ in sed basic regex (BSD sed matches literal +)' 'use sed -E with POSIX + or write [x][x]*' vsh12-sed-gnu-plus # portable-shell-ok
            found=1
        fi

    done < "$file"

    if ! check_web_status "$file"; then
        found=1
    fi

    if ! check_bash4_shebang "$file"; then
        found=1
    fi

    CHECKED=$((CHECKED + 1))
    if [[ "$found" -eq 1 ]]; then
        VIOLATIONS=$((VIOLATIONS + 1))
    fi
}

# VSH13 web call whose HTTP status is discarded.
#
# Its own pass, because the pattern spans continuation lines and the
# line-based loop above cannot see it:
#
#   TOKEN=$(curl -sf -X POST \
#     "https://api.example/thing" \
#     | jq -r '.token')
#
# is one logical command. curl's exit status is thrown away — under
# pipefail the job dies with a bare "exit code 22" and no HTTP status;
# without pipefail the status becomes jq's and the failure is silent.
# Every github-mirror job in the workspace failed this way on 2026-08-20
# and reported nothing usable for a day.
check_web_status() {
    local file="$1"
    local logical="" start_line=0 line_no=0 line found=0

    while IFS= read -r line; do
        line_no=$((line_no + 1))

        [[ "$line" =~ ^[[:space:]]*# ]] && continue

        [[ -z "$logical" ]] && start_line="$line_no"
        logical+=" ${line%\\}"

        # Command continues on the next line — keep accumulating.
        [[ "$line" == *\\ ]] && continue

        if [[ "$logical" =~ (curl|wget)[[:space:]] ]] \
            && [[ "$logical" == *'$('* ]] \
            && [[ "$logical" == *'|'* ]] \
            && [[ "$logical" != *portable-shell-ok* ]] \
            && [[ "$logical" != *http_code* ]] \
            && [[ "$logical" != *--fail-with-body* ]] \
            && [[ "$logical" != *--write-out* ]]; then
            emit VSH13 "$file" "$start_line" \
                'web call piped inside $() discards its HTTP status' \
                "capture it with -w '%{http_code}' -o FILE and branch on it, or use curl --fail-with-body" \
                vsh13-web-call-status-discarded # portable-shell-ok
            found=1
        fi

        logical=""
    done < "$file"

    return "$((found == 0 ? 0 : 1))"
}

# VSH14 bash-4 syntax under a #!/bin/bash shebang.
#
# Its own pass, because the line loop above skips comments and the
# shebang is one. macOS ships bash 3.2 at /bin/bash, so pinning that
# interpreter while using declare -A, mapfile, readarray or ${v^^}
# aborts the script at that line — on 2026-09-08 orchestrate.sh died on
# its top-level `declare -A` before any subcommand ran, taking every
# `just e2e-*` recipe on the dev Mac with it. Either half alone is fine:
# #!/usr/bin/env bash finds a modern bash on PATH, and /bin/bash runs
# POSIX-ish bodies everywhere. Only the pairing is a defect.
check_bash4_shebang() {
    local file="$1"
    local shebang line line_no=0 found=0

    IFS= read -r shebang < "$file" || return 0
    [[ "$shebang" =~ ^#![[:space:]]*/bin/bash ]] || return 0

    while IFS= read -r line; do
        line_no=$((line_no + 1))

        [[ "$line" =~ ^[[:space:]]*# ]] && continue
        [[ "$line" =~ portable-shell-ok ]] && continue

        if [[ "$line" =~ (declare|local|typeset)[[:space:]]+-[A-Za-z]*A[[:space:]] ]] \
            || [[ "$line" =~ ^[[:space:]]*(mapfile|readarray)[[:space:]] ]] \
            || [[ "$line" =~ \$\{[A-Za-z_][A-Za-z0-9_]*(\^\^|,,) ]]; then
            emit VSH14 "$file" "$line_no" \
                'bash-4 syntax under a #!/bin/bash shebang (macOS /bin/bash is 3.2)' \
                'switch the shebang to #!/usr/bin/env bash' \
                vsh14-bash4-under-bin-bash # portable-shell-ok
            found=1
        fi
    done < "$file"

    return "$((found == 0 ? 0 : 1))"
}

# If arguments given, check those files. Otherwise, check staged files.
if [[ $# -gt 0 ]]; then
    files=("$@")
else
    # Get staged .sh and script files
    mapfile -t files < <(git diff --cached --name-only --diff-filter=ACM 2>/dev/null \
        | grep -E '\.(sh|bash)$' || true)

    # Also check staged .just files (extract shell blocks)
    mapfile -t just_files < <(git diff --cached --name-only --diff-filter=ACM 2>/dev/null \
        | grep -E '\.just$' || true)
    files+=("${just_files[@]}")
fi

for f in "${files[@]}"; do
    [[ -f "$f" ]] || continue
    # Detector self-tests carry intentionally-violating fixture heredocs;
    # scanning them would flag the fixtures (see check-portable-shell.test.sh).
    case "$f" in */tests/*.test.sh|tests/*.test.sh) continue ;; esac
    check_file "$f"
done

if [[ "$VIOLATIONS" -gt 0 ]]; then
    echo ""
    printf 'FAILED: %d file(s) with non-portable shell patterns.\n' "$VIOLATIONS"
    echo "See: .claude/rules/portable-shell.md"
    exit 1
fi

if [[ "$CHECKED" -gt 0 ]]; then
    printf '  Portable shell OK (%d file(s) checked)\n' "$CHECKED"
fi
