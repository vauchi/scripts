#!/usr/bin/env bash
# SPDX-FileCopyrightText: 2026 Mattia Egloff <mattia.egloff@pm.me>
#
# SPDX-License-Identifier: GPL-3.0-or-later

# regen-snapshots.sh — Detect snapshot tooling in the host repo and
# run the matching regen invocation. Origin:
# `_private/docs/problems/2026-05-03-vet-autosync-stale-snapshots`
# Phase 2 (G1') — when a cargo-vet auto-sync MR's Cargo.lock bump
# moves vauchi-core to a rev that touched UI code, run snapshot
# regen so the consumer's snapshots stay in sync with the new
# `ScreenModel` shape.
#
# Usage:
#   regen-snapshots.sh OLD_CORE_SHA NEW_CORE_SHA
#
# Args:
#   OLD_CORE_SHA  — vauchi-core git SHA from Cargo.lock before the bump
#   NEW_CORE_SHA  — vauchi-core git SHA from Cargo.lock after the bump
#
# Both args are required for log context (the helper echoes them so
# CI logs explain why regen ran). The caller (vet-autofix.sh) is
# responsible for gating on OLD != NEW + UI-files-non-empty before
# invoking — the helper only handles tooling detection + dispatch.
#
# Detection is by *presence of snapshot artefacts* (insta dep in
# Cargo.toml, or any `*.snap` file under the workspace) — not by
# repo name. New repos enter scope automatically when they grow
# snapshot tests.
#
# Currently only the Rust `cargo insta` family is supported because
# it is the only tooling used in repos where vet-autofix runs (cli,
# tui, relay). Adding a new family means: extend the detection here,
# add cases to regen-snapshots.test.sh.
#
# Exit:
#   0   — regen ran clean (or no tooling detected — relay-shape repo)
#   !=0 — regen invocation failed; caller should fall back to
#         Phase 1 (warning-only) shape.

set -euo pipefail

if [[ $# -lt 2 ]]; then
    printf 'usage: regen-snapshots.sh OLD_CORE_SHA NEW_CORE_SHA\n' >&2
    exit 2
fi

OLD_CORE_SHA="$1"
NEW_CORE_SHA="$2"

# ── Tooling detection ────────────────────────────────────────────
# Two independent signals; either is sufficient. Independent so a
# repo that uses insta only via a workspace member (no top-level
# Cargo.toml entry) still dispatches via the *.snap-file signal.

has_insta_dep=false
if [[ -f Cargo.toml ]] && grep -q '^insta[[:space:]]*=' Cargo.toml; then
    has_insta_dep=true
fi

has_snap_files=false
# POSIX-ish find: -name + -print + head. Avoids GNU-only -quit so
# this stays portable to BusyBox (alpine CI). One trailing newline
# from head is enough to flip the flag.
if [[ -n "$(find . -type f -name '*.snap' -print 2>/dev/null | head -n 1)" ]]; then
    has_snap_files=true
fi

# ── Dispatch ─────────────────────────────────────────────────────

if $has_insta_dep || $has_snap_files; then
    printf 'regen-snapshots: cargo-insta detected (insta_dep=%s snap_files=%s)\n' \
        "$has_insta_dep" "$has_snap_files"
    printf 'regen-snapshots: regenerating against vauchi-core %s → %s\n' \
        "${OLD_CORE_SHA:0:8}" "${NEW_CORE_SHA:0:8}"

    if ! command -v cargo-insta >/dev/null 2>&1; then
        printf 'regen-snapshots: cargo-insta not on PATH; install with `cargo install cargo-insta --locked`\n' >&2
        printf 'regen-snapshots: attempting `cargo insta` via the cargo subcommand resolver instead\n'
    fi

    # `cargo insta test --accept --workspace` re-runs the test suite
    # and accepts any pending snapshot updates as the new baseline.
    # `--workspace` covers crates without insta in their own Cargo.toml
    # (e.g. workspace members that only re-export render output).
    cargo insta test --accept --workspace
    exit $?
fi

# ── No tooling detected — relay-shape repo, exit clean ───────────
printf 'regen-snapshots: no snapshot tooling detected (no insta dep, no *.snap files) — skipping\n'
exit 0
