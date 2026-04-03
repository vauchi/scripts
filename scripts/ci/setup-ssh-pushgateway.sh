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

setup_ssh_pushgateway() {
    if [ -f ~/.ssh/id_ed25519 ]; then
        # Already set up (e.g. by deploy script)
        PUSHGATEWAY_SSH_MODE="full"
        return 0
    fi

    # Try full-access key first (protected — only available on main)
    if [ -n "${DEPLOY_SSH_PRIVATE_KEY:-}" ]; then
        if _decode_key_file "$DEPLOY_SSH_PRIVATE_KEY"; then
            PUSHGATEWAY_SSH_MODE="full"
            return 0
        fi
        echo "setup-ssh: DEPLOY_SSH_PRIVATE_KEY decode failed" >&2
    fi

    # Try restricted pushgateway key (unprotected — available on all branches)
    if [ -n "${PUSHGATEWAY_SSH_KEY:-}" ]; then
        if _decode_key_file "$PUSHGATEWAY_SSH_KEY"; then
            PUSHGATEWAY_SSH_MODE="restricted"
            return 0
        fi
        echo "setup-ssh: PUSHGATEWAY_SSH_KEY decode failed" >&2
    fi

    echo "setup-ssh: no SSH key available, push will be skipped" >&2
    return 0
}

# Push metrics to Pushgateway.
#
# Usage: pushgateway_push "$METRICS_TEXT" "/metrics/job/vauchi_foo/repo/bar"
#
# Returns 0 on success, 1 on failure (caller decides if fatal).
pushgateway_push() {
    local metrics_text="$1"
    local url_path="$2"

    # Direct URL (highest priority)
    if [ -n "${PUSHGATEWAY_URL:-}" ]; then
        if echo "$metrics_text" | curl -s --fail --connect-timeout 3 --max-time 5 \
                --data-binary @- "${PUSHGATEWAY_URL}${url_path}" 2>/dev/null; then
            return 0
        fi
    fi

    # SSH push
    case "$PUSHGATEWAY_SSH_MODE" in
        full)
            # Full-access key: send the curl command to execute on the VPS
            # shellcheck disable=SC2029  # intentional client-side expansion
            if echo "$metrics_text" | ssh -o ConnectTimeout=5 \
                    "${PUSHGATEWAY_SSH_USER}@${PUSHGATEWAY_SSH_HOST}" \
                    "curl -s --fail --max-time 5 --data-binary @- http://localhost:9091${url_path}" 2>/dev/null; then
                return 0
            fi
            ;;
        restricted)
            # Restricted key: server-side forced command (push-proxy.sh)
            # validates the path and proxies stdin to curl.
            # The SSH "command" is just the URL path — push-proxy.sh reads it
            # from SSH_ORIGINAL_COMMAND.
            # shellcheck disable=SC2029
            if echo "$metrics_text" | ssh -o ConnectTimeout=5 \
                    "${PUSHGATEWAY_SSH_USER}@${PUSHGATEWAY_SSH_HOST}" \
                    "${url_path}" 2>/dev/null; then
                return 0
            fi
            ;;
    esac

    return 1
}
