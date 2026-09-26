#!/usr/bin/env bash
# SPDX-FileCopyrightText: 2026 Mattia Egloff <mattia.egloff@pm.me>
#
# SPDX-License-Identifier: GPL-3.0-or-later
#
# Work-board claim validator — VGT05: every `- [ ]` item under
# `## In Progress` must carry a session id (@...-session-...) and an
# `(expires YYYY-MM-DDT<hh:mm>Z)` timestamp, so audit sessions can
# release expired claims instead of items blocking forever; the
# required sections must exist.
# Rule page: _private/docs/lint-errors/vgt05-work-board-claims.md
# Self-test: scripts/tests/check-work-board.test.sh
# Called by: `just session-end`.

set -euo pipefail

BOARD="${1:-_private/docs/work-board.md}"

if [[ ! -f "$BOARD" ]]; then
    echo "check-work-board: board file not found: $BOARD" >&2
    exit 2
fi

# ADR-073: once the queue moved to GitLab issues the board is a pointer
# file with no items or claims, so there is nothing left to validate.
if head -5 "$BOARD" | grep -q '^# Work Board — moved to GitLab issues'; then
    echo "  Work board moved to GitLab issues — nothing to check ($BOARD)"
    exit 0
fi

# Items are a `- [ ]` line plus following indented continuation lines;
# claims may sit on any line of the item.
if ! awk -v board="$BOARD" '
    function flush_item() {
        if (item != "" && (!has_sid || !has_exp)) {
            printf "  %s:%d: VGT05: In-Progress item lacks %s — fix: append @<session-id> (expires YYYY-MM-DDT22:00Z) to the claim line. [_private/docs/lint-errors/vgt05-work-board-claims.md]\n",
                board, item_line, (has_sid ? "an expiry" : "a session id")
            bad = 1
        }
        item = ""; has_sid = 0; has_exp = 0
    }
    /^## / {
        flush_item()
        in_prog = ($0 ~ /^## In Progress/)
        if ($0 ~ /^## In Progress/) saw_prog = 1
        if ($0 ~ /^## Done/)        saw_done = 1
    }
    in_prog && /^- \[ \]/ { flush_item(); item = $0; item_line = NR }
    in_prog && item != "" {
        if ($0 ~ /@[A-Za-z0-9-]*session[A-Za-z0-9-]*/) has_sid = 1
        if ($0 ~ /\(expires 20[0-9][0-9]-[0-9][0-9]-[0-9][0-9]T[0-9][0-9]:[0-9][0-9]Z\)/) has_exp = 1
        # a non-indented, non-item line ends the current item
        if ($0 !~ /^- \[ \]/ && $0 !~ /^[ \t]/ && $0 !~ /^$/ && $0 !~ /^<!--/) flush_item()
    }
    END {
        flush_item()
        if (!saw_prog) { printf "  %s: VGT05: missing \"## In Progress\" section — fix: restore the required board sections. [_private/docs/lint-errors/vgt05-work-board-claims.md]\n", board; bad = 1 }
        if (!saw_done) { printf "  %s: VGT05: missing \"## Done\" section — fix: restore the required board sections. [_private/docs/lint-errors/vgt05-work-board-claims.md]\n", board; bad = 1 }
        exit bad
    }
' "$BOARD"; then
    echo ""
    echo "FAILED: work-board claim format violations."
    exit 1
fi

echo "  Work board OK ($BOARD)"
