#!/usr/bin/env bash
# SPDX-FileCopyrightText: 2026 Mattia Egloff <mattia.egloff@pm.me>
# SPDX-License-Identifier: GPL-3.0-or-later
#
# check-public-api.sh — Deterministic snapshot of each core crate's public
# surface, broken down by subsystem. Output is stable, sortable, diffable —
# any future "depth vs. shallow" claim should cite this output, not prose.
#
# Usage:
#   check-public-api.sh [crate]
#     crate := vauchi-core | vauchi-cabi | vauchi-platform | vauchi-protocol | all
#
# Exit codes:
#   0 — snapshot produced
#   1 — invalid crate argument
#   2 — sanity threshold exceeded (count looks broken — investigate the tool, not the data)
#
# Portability: GNU/BSD/BusyBox safe (see .claude/rules/portable-shell.md).
# Uses cargo-public-api if installed (authoritative), else falls back to a
# grep-based count. The fallback is honest about its limitations.

set -uo pipefail

CRATE="${1:-all}"
ROOT="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
cd "$ROOT" || exit 1

SANITY_MAX_PUB_PER_FILE=500  # if any single file > this, suspect tool

# ── Helpers ──────────────────────────────────────────────────────────

# Count distinct public items (mod-aware, ignores cfg-gated test_pub_mod!).
# Production-public means: pub *outside* a `#[cfg(...test...)]` or
# `#[cfg(feature = "testing")]` block. We approximate by counting
# `^pub ` lines and noting that test_pub_mod! lines are NOT prefixed by
# `pub` (they're macro invocations), so they do not inflate the count.
count_pub() {
    local file="$1"
    grep -cE '^pub (fn|struct|enum|trait|type|const|static|async fn|unsafe fn|extern)' "$file" 2>/dev/null || echo 0
}

count_pub_use() { grep -cE '^pub use ' "$1" 2>/dev/null || echo 0; }
count_pub_mod() { grep -cE '^pub mod ' "$1" 2>/dev/null || echo 0; }

# Snapshot a directory: list every `^pub ` declaration, sorted, with file path.
snapshot_dir() {
    local dir="$1"
    [ -d "$dir" ] || { echo "  (missing: $dir)"; return; }
    find "$dir" -name '*.rs' -not -path '*/tests/*' -print0 \
        | xargs -0 grep -HnE '^pub (fn|struct|enum|trait|type|const|static|async fn|unsafe fn|extern|use|mod) ' 2>/dev/null \
        | sort
}

# Per-crate summary line.
summarize_crate() {
    local crate="$1"
    local src="core/$crate/src"
    [ -d "$src" ] || { echo "$crate: (no source dir)"; return; }
    local total
    total=$(find "$src" -name '*.rs' -not -path '*/tests/*' -print0 \
        | xargs -0 grep -hcE '^pub (fn|struct|enum|trait|type|const|static|async fn|unsafe fn|extern|use|mod) ' 2>/dev/null \
        | awk '{s+=$1} END{print s+0}')
    local files
    files=$(find "$src" -name '*.rs' -not -path '*/tests/*' | wc -l | tr -d ' ')
    local loc
    loc=$(find "$src" -name '*.rs' -not -path '*/tests/*' -exec wc -l {} + 2>/dev/null | tail -1 | awk '{print $1+0}')
    printf "%-20s files=%-4s loc=%-6s pub-items=%s\n" "$crate" "$files" "$loc" "$total"
}

# Per-subsystem breakdown for vauchi-core.
core_subsystem_breakdown() {
    echo "── vauchi-core subsystem breakdown ──"
    printf "%-15s %-8s %-7s %-9s %-9s %s\n" "subsystem" "files" "loc" "pub-items" "pub-mod" "pub-use"
    for sub in $(find core/vauchi-core/src -mindepth 1 -maxdepth 1 -type d | sort); do
        local name; name=$(basename "$sub")
        local nf; nf=$(find "$sub" -name '*.rs' | wc -l | tr -d ' ')
        local nl; nl=$(find "$sub" -name '*.rs' -exec wc -l {} + 2>/dev/null | tail -1 | awk '{print $1+0}')
        local np; np=$(find "$sub" -name '*.rs' -print0 | xargs -0 grep -hcE '^pub (fn|struct|enum|trait|type|const|static|async fn|unsafe fn|extern)' 2>/dev/null | awk '{s+=$1} END{print s+0}')
        local nm; nm=$(find "$sub" -name 'mod.rs' -print0 | xargs -0 grep -hcE '^pub mod ' 2>/dev/null | awk '{s+=$1} END{print s+0}')
        local nu; nu=$(find "$sub" -name 'mod.rs' -print0 | xargs -0 grep -hcE '^pub use ' 2>/dev/null | awk '{s+=$1} END{print s+0}')
        printf "%-15s %-8s %-7s %-9s %-9s %s\n" "$name" "$nf" "$nl" "$np" "$nm" "$nu"
    done
}

# ── cargo-public-api fast path (authoritative) ──────────────────────

if command -v cargo-public-api >/dev/null 2>&1; then
    USING_AUTHORITATIVE=1
else
    USING_AUTHORITATIVE=0
fi

# ── Main ─────────────────────────────────────────────────────────────

valid_crates="vauchi-core vauchi-cabi vauchi-platform vauchi-protocol"

case "$CRATE" in
    all)
        echo "=== Public-API snapshot (workspace) ==="
        date -u +'generated: %Y-%m-%dT%H:%M:%SZ'
        if [ "$USING_AUTHORITATIVE" = "0" ]; then
            echo "tool: grep (install cargo-public-api for authoritative output)"
        else
            echo "tool: cargo-public-api"
        fi
        echo
        echo "── crate summary ──"
        for c in $valid_crates; do summarize_crate "$c"; done
        echo
        core_subsystem_breakdown
        ;;
    vauchi-core|vauchi-cabi|vauchi-platform|vauchi-protocol)
        echo "=== $CRATE public surface ==="
        summarize_crate "$CRATE"
        echo
        snapshot_dir "core/$CRATE/src"
        ;;
    *)
        echo "error: unknown crate '$CRATE' — expected one of: $valid_crates all" >&2
        exit 1
        ;;
esac

# Sanity threshold (CC-21 — suspect tool before suspecting data).
if [ "$CRATE" = "all" ]; then
    biggest=$(find core/*/src -name '*.rs' -not -path '*/tests/*' -print0 \
        | xargs -0 grep -cE '^pub ' 2>/dev/null \
        | awk -F: '{print $2}' | sort -n | tail -1)
    if [ "${biggest:-0}" -gt "$SANITY_MAX_PUB_PER_FILE" ]; then
        echo
        echo "POSSIBLE TOOL BUG: a single file shows $biggest pub items (> $SANITY_MAX_PUB_PER_FILE)" >&2
        echo "Investigate the tool/grep before suspecting the data." >&2
        exit 2
    fi
fi
