#!/usr/bin/env bash
# SPDX-FileCopyrightText: 2026 Mattia Egloff <mattia.egloff@pm.me>
# SPDX-License-Identifier: GPL-3.0-or-later

# setup-ssh-pushgateway.sh — Configure SSH for Pushgateway access in CI.
#
# Source this file, call setup_ssh_pushgateway, then use pushgateway_push.
#
# Key precedence:
#   1. PUSHGATEWAY_URL      — direct HTTP push (no SSH needed)
#   2. DEPLOY_SSH_PRIVATE_KEY — full VPS access (protected, main only)
#   3. PUSHGATEWAY_SSH_KEY   — restricted pushgateway-only key (unprotected,
#                              all branches). Server-side forced command
#                              validates the path and proxies to curl.
#
# Both key variables are file-type CI variables (path to base64-encoded key).
# Registers cleanup trap to remove key on exit.

# Which SSH mode was loaded: "full", "restricted", or ""
set -euo pipefail

PUSHGATEWAY_SSH_MODE=""

PUSHGATEWAY_SSH_HOST="${PUSHGATEWAY_SSH_HOST:-bold-hopper-vps}"
PUSHGATEWAY_SSH_IP="${PUSHGATEWAY_SSH_IP:-87.106.25.46}"
PUSHGATEWAY_SSH_USER="${PUSHGATEWAY_SSH_USER:-vauchi}"

# Decode a base64-encoded key file to ~/.ssh/id_ed25519.
# Tries both GNU and macOS base64 flags.
_decode_key_file() {
    local key_path="$1"
    mkdir -p ~/.ssh

    if ! base64 -d -i "$key_path" > ~/.ssh/id_ed25519 2>/dev/null; then
        rm -f ~/.ssh/id_ed25519
    fi
    if [ ! -s ~/.ssh/id_ed25519 ] \
       && ! base64 -d "$key_path" > ~/.ssh/id_ed25519 2>/dev/null; then
        rm -f ~/.ssh/id_ed25519
        return 1
    fi

    if [ ! -s ~/.ssh/id_ed25519 ]; then
        rm -f ~/.ssh/id_ed25519
        return 1
    fi

    chmod 600 ~/.ssh/id_ed25519

    if [ ! -f ~/.ssh/config ] || ! grep -q "$PUSHGATEWAY_SSH_HOST" ~/.ssh/config 2>/dev/null; then
        cat >> ~/.ssh/config <<SSHEOF
Host ${PUSHGATEWAY_SSH_HOST}
  HostName ${PUSHGATEWAY_SSH_IP}
  User ${PUSHGATEWAY_SSH_USER}
  StrictHostKeyChecking accept-new
SSHEOF
        chmod 600 ~/.ssh/config
    fi

    trap 'rm -f ~/.ssh/id_ed25519' EXIT
    return 0
}

# Returns 0 when a key was loaded, AND when no key variable was set at all.
# Returns non-zero when a key variable WAS set and could not be decoded.
#
# That distinction is the whole contract. "No key variable is set" is
# legitimate on an unprotected ref, where the protected variable genuinely
# cannot exist — skipping there is correct. "A key variable is set and does
# not decode" is a corrupt credential, and it is exactly the 2026-07-28
# fault, where DEPLOY_SSH_PRIVATE_KEY's GitLab type was flipped from
# Variable to File and `base64 -d` began failing. Collapsing the two into
# `return 0` meant that fault presented as a quiet skip.
#
# Callers invoke this bare under `set -e`, so a corrupt credential now
# aborts the job with the message below rather than pushing nothing and
# reporting success. A caller that genuinely wants to tolerate it must say
# so explicitly, which makes the choice reviewable.
setup_ssh_pushgateway() {
    local key_offered=0

    if [ -f ~/.ssh/id_ed25519 ]; then
        # Already set up (e.g. by deploy script)
        PUSHGATEWAY_SSH_MODE="full"
        return 0
    fi

    # Try full-access key first (protected — only available on main)
    if [ -n "${DEPLOY_SSH_PRIVATE_KEY:-}" ]; then
        key_offered=1
        if _decode_key_file "$DEPLOY_SSH_PRIVATE_KEY"; then
            PUSHGATEWAY_SSH_MODE="full"
            return 0
        fi
        echo "setup-ssh: DEPLOY_SSH_PRIVATE_KEY decode failed" >&2
    fi

    # Try restricted pushgateway key (unprotected — available on all branches)
    if [ -n "${PUSHGATEWAY_SSH_KEY:-}" ]; then
        key_offered=1
        if _decode_key_file "$PUSHGATEWAY_SSH_KEY"; then
            PUSHGATEWAY_SSH_MODE="restricted"
            return 0
        fi
        echo "setup-ssh: PUSHGATEWAY_SSH_KEY decode failed" >&2
    fi

    if [ "$key_offered" -eq 1 ]; then
        echo "setup-ssh: a key variable is set but NO key could be decoded —" >&2
        echo "setup-ssh: treating this as a corrupt credential, not an absent one." >&2
        echo "setup-ssh: check the variable's GitLab type (Variable vs File)." >&2
        return 1
    fi

    echo "setup-ssh: no SSH key variable is set — nothing to decode, skipping" >&2
    return 0
}

# Push metrics to Pushgateway.
#
# Usage: pushgateway_push "$METRICS_TEXT" "/metrics/job/vauchi_foo/repo/bar"
#
# Returns 0 on success, 1 on failure (caller decides if fatal).
# Stamp the payload with the transport that is about to carry it, so a
# received metric says how it arrived.
#
# WHY: this helper falls back silently across three transports, and the
# metric it delivers looked identical whichever one worked. Between
# 2026-07-28 and 2026-08-01 the production deploy key was rejected while
# `EngineeringMetricsStale` (a two-day threshold) stayed quiet for four
# days — the pushes had quietly landed on the restricted key instead, and
# nothing recorded that. Freshness proved neither credential.
#
# A fallback that hides which branch it took converts a credential failure
# into silence. Emitting the branch makes `vauchi_push_transport{mode=
# "full"}` going stale a queryable statement that the deploy key stopped
# working, rather than something to infer.
_pushgateway_stamp() {
    printf '%s\nvauchi_push_transport{mode="%s"} 1\n' "$1" "$2"
}

pushgateway_push() {
    local metrics_text="$1"
    local url_path="$2"

    # Direct URL (highest priority). Note this exercises NO credential —
    # a push that succeeds here says nothing about either SSH key.
    if [ -n "${PUSHGATEWAY_URL:-}" ]; then
        if _pushgateway_stamp "$metrics_text" direct |
            curl -s --fail --connect-timeout 3 --max-time 5 \
                --data-binary @- "${PUSHGATEWAY_URL}${url_path}" 2>/dev/null; then
            echo "pushgateway: delivered via direct URL (no SSH credential exercised)" >&2
            return 0
        fi
    fi

    # SSH push
    case "$PUSHGATEWAY_SSH_MODE" in
        full)
            # Full-access key: send the curl command to execute on the VPS
            # shellcheck disable=SC2029  # intentional client-side expansion
            if _pushgateway_stamp "$metrics_text" full |
                ssh -o ConnectTimeout=5 \
                    "${PUSHGATEWAY_SSH_USER}@${PUSHGATEWAY_SSH_HOST}" \
                    "curl -s --fail --max-time 5 --data-binary @- http://localhost:9091${url_path}" 2>/dev/null; then
                echo "pushgateway: delivered via the full deploy key" >&2
                return 0
            fi
            ;;
        restricted)
            # Restricted key: server-side forced command (push-proxy.sh)
            # validates the path and proxies stdin to curl.
            # The SSH "command" is just the URL path — push-proxy.sh reads it
            # from SSH_ORIGINAL_COMMAND.
            # shellcheck disable=SC2029
            if _pushgateway_stamp "$metrics_text" restricted |
                ssh -o ConnectTimeout=5 \
                    "${PUSHGATEWAY_SSH_USER}@${PUSHGATEWAY_SSH_HOST}" \
                    "${url_path}" 2>/dev/null; then
                echo "pushgateway: delivered via the restricted pushgateway key" >&2
                return 0
            fi
            ;;
    esac

    echo "pushgateway: NO transport delivered the metric" >&2
    return 1
}
