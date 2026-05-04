#!/usr/bin/env bash
# SPDX-FileCopyrightText: 2026 Mattia Egloff <mattia.egloff@pm.me>
#
# SPDX-License-Identifier: GPL-3.0-or-later

# check-aead.sh — Enforce ADR-046 (HPKE-internal AEAD scope).
#
# ADR-046 binds HPKE-internal AEAD to ChaCha20-Poly1305 — the
# chacha-family option from RFC 9180's negotiable set. AES-128-GCM
# and AES-256-GCM are forbidden inside HPKE because:
#
#   1. They diverge from ADR-019's anti-AES intent (mobile fleet
#      uniformity, no AES-NI dependency, constant-time on all
#      architectures).
#   2. Mixing ciphers across the gateway fleet introduces a
#      fingerprinting vector — the HPKE encap header carries the
#      negotiated `Aead` ID, observable by the gateway operator.
#
# This script flags any `hpke::Aead::Aes128Gcm` or
# `hpke::Aead::Aes256Gcm` symbol in *.rs files outside an explicit
# allow-list.
#
# Usage:
#   check-aead.sh <repo_root> [<repo_root> ...]
#
# Example:
#   check-aead.sh core relay e2e cli tui ohttp-relay
#
# Allow-list (inline):
#   - Lines tagged with the sentinel `ADR-046-EXEMPT: <reason>` are
#     exempt. Each exemption MUST include a one-line reason after
#     the marker. Use sparingly — the long-term goal is zero
#     exemptions.
#
# Returns:
#   0 — no forbidden HPKE AEAD usage outside the allow-list.
#   1 — at least one violation reported (script prints file:line:code).
#   2 — usage error.
#
# Composability: tested standalone (no `set -e` traps that surface
# only via parent shell). Safe to invoke from gate-push or pre-commit.

set -euo pipefail

if [ $# -lt 1 ]; then
    echo "Usage: $0 <repo_root> [<repo_root> ...]" >&2
    echo "Example: $0 core relay e2e cli tui ohttp-relay" >&2
    exit 2
fi

# Pattern: literal symbols that select the forbidden AES AEAD in
# the `hpke` crate. We intentionally do NOT match all bare
# `Aes128Gcm`/`Aes256Gcm` occurrences — those exist in TLS / Noise /
# application-AEAD code paths governed by other ADRs. Only the
# `hpke::Aead::` prefix matters for ADR-046.
PATTERN='hpke::Aead::(Aes128Gcm|Aes256Gcm)'
SENTINEL='ADR-046-EXEMPT'

VIOLATIONS=0

for ROOT in "$@"; do
    if [ ! -d "$ROOT" ]; then
        echo "Warning: $ROOT is not a directory, skipping" >&2
        continue
    fi

    # Use ripgrep if available (faster + handles binary skip + .gitignore).
    # Fall back to portable grep otherwise. Both produce file:line:content.
    if command -v rg &>/dev/null; then
        HITS=$(rg --no-messages --with-filename --line-number --no-heading \
            --type rust -e "$PATTERN" "$ROOT" 2>/dev/null || true)
    else
        HITS=$(grep -rnE --include='*.rs' "$PATTERN" "$ROOT" 2>/dev/null || true)
    fi

    while IFS= read -r HIT; do
        [ -z "$HIT" ] && continue

        # Each HIT is `file:line:content` (ripgrep) or
        # `file:line:content` (grep -n). Same shape — split on the
        # first two `:` only, keep the rest as content.
        FILE=$(echo "$HIT" | awk -F: '{print $1}')
        LINE=$(echo "$HIT" | awk -F: '{print $2}')
        CONTENT=$(echo "$HIT" | cut -d: -f3-)

        # Allow-list check 1: sentinel on the same line.
        if echo "$CONTENT" | grep -qF "$SENTINEL"; then
            continue
        fi

        # Allow-list check 2: sentinel on the line above (lets
        # callers attach the reason to a `// ADR-046-EXEMPT: ...`
        # comment immediately preceding the AEAD selector).
        PREV_LINE=$((LINE - 1))
        if [ "$PREV_LINE" -ge 1 ]; then
            PREV_CONTENT=$(sed -n "${PREV_LINE}p" "$FILE" 2>/dev/null || echo "")
            if echo "$PREV_CONTENT" | grep -qF "$SENTINEL"; then
                continue
            fi
        fi

        # Violation — emit a clear, machine-grep-able line.
        echo "$FILE:$LINE: $CONTENT" >&2
        VIOLATIONS=$((VIOLATIONS + 1))
    done <<< "$HITS"
done

if [ "$VIOLATIONS" -gt 0 ]; then
    echo "" >&2
    echo "ERROR: $VIOLATIONS HPKE AEAD violation(s) found." >&2
    echo "" >&2
    echo "ADR-046 binds HPKE-internal AEAD to ChaCha20-Poly1305." >&2
    echo "If you have a legitimate need (e.g. testing legacy" >&2
    echo "compatibility), add an inline exemption:" >&2
    echo "" >&2
    echo "  // ADR-046-EXEMPT: <one-line reason>" >&2
    echo "  hpke::Aead::Aes128Gcm" >&2
    echo "" >&2
    echo "Or on the same line:" >&2
    echo "" >&2
    echo "  hpke::Aead::Aes128Gcm, // ADR-046-EXEMPT: <reason>" >&2
    echo "" >&2
    exit 1
fi

echo "ADR-046 OK: no forbidden HPKE AEAD usage."
