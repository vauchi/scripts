#!/usr/bin/env bash
# SPDX-FileCopyrightText: 2026 Mattia Egloff <mattia.egloff@pm.me>
#
# SPDX-License-Identifier: GPL-3.0-or-later
#
# VSC01 — a cargo-vet [[audits]] entry is a human attestation that
# someone read the crate's source. AI sessions cannot truthfully
# attest, and CI's `cargo vet --locked` cannot tell a fabricated audit
# from a real one — this guard is the only line of defense.
# Human maintainers commit real audits with VAUCHI_HUMAN_AUDIT=1.
# Rule page: _private/docs/lint-errors/vsc01-no-ai-audits.md
# Self-test: scripts/tests/check-vet-audits.test.sh
# Called by: pre-commit (staged diff of supply-chain/audits.toml)

set -euo pipefail

# shellcheck source=lib/common.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib/common.sh"

if [[ "${VAUCHI_HUMAN_AUDIT:-0}" == "1" ]]; then
    exit 0
fi

if [[ "${1:-}" == "--diff-file" ]]; then
    DIFF_CONTENT="$(cat "${2:?--diff-file needs a path}")"
else
    DIFF_CONTENT="$(git diff --cached --unified=0 -- '*supply-chain/audits.toml' 2>/dev/null || true)"
fi

if printf '%s\n' "$DIFF_CONTENT" | grep -qE '^\+\[\[audits\.'; then
    added="$(printf '%s\n' "$DIFF_CONTENT" | grep -E '^\+\[\[audits\.' | head -3)"
    log_error "$added"
    die "VSC01: staged diff adds a cargo-vet [[audits]] entry (a human attestation an AI cannot make) — fix: add [[exemptions.<crate>]] in supply-chain/config.toml instead; humans commit real audits with VAUCHI_HUMAN_AUDIT=1. [_private/docs/lint-errors/vsc01-no-ai-audits.md]"
fi
exit 0
