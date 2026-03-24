#!/usr/bin/env bash
# SPDX-FileCopyrightText: 2026 Mattia Egloff <mattia.egloff@pm.me>
# SPDX-License-Identifier: GPL-3.0-or-later

# setup-ssh-pushgateway.sh — Configure SSH for Pushgateway access in CI.
#
# Source this file and call setup_ssh_pushgateway from push-*.sh scripts.
#
# Required env vars (when DEPLOY_SSH_PRIVATE_KEY is set):
#   DEPLOY_SSH_PRIVATE_KEY  — path to file containing base64-encoded key
#                            (GitLab file-type CI variable)
#   PUSHGATEWAY_SSH_HOST    — hostname for SSH config
#   PUSHGATEWAY_SSH_IP      — IP address for SSH config
#   PUSHGATEWAY_SSH_USER    — SSH user
#
# Skips if key file already exists or DEPLOY_SSH_PRIVATE_KEY is unset/empty.
# Registers cleanup trap to remove key on exit.

setup_ssh_pushgateway() {
    if [ -z "${DEPLOY_SSH_PRIVATE_KEY:-}" ]; then
        echo "setup-ssh: DEPLOY_SSH_PRIVATE_KEY not set, skipping SSH setup" >&2
        return 0
    fi

    if [ -f ~/.ssh/id_ed25519 ]; then
        return 0
    fi

    mkdir -p ~/.ssh

    # Portable base64 decode: macOS needs -i flag, GNU takes positional arg
    if ! base64 -d -i "$DEPLOY_SSH_PRIVATE_KEY" > ~/.ssh/id_ed25519 2>/dev/null \
       && ! base64 -d "$DEPLOY_SSH_PRIVATE_KEY" > ~/.ssh/id_ed25519 2>/dev/null; then
        echo "ERROR: Failed to decode DEPLOY_SSH_PRIVATE_KEY (base64 -d failed)" >&2
        echo "Check that the CI variable contains a valid base64-encoded file." >&2
        rm -f ~/.ssh/id_ed25519
        return 1
    fi

    # Verify key is non-empty (base64 -d of empty string succeeds silently)
    if [ ! -s ~/.ssh/id_ed25519 ]; then
        echo "ERROR: DEPLOY_SSH_PRIVATE_KEY decoded to empty file" >&2
        rm -f ~/.ssh/id_ed25519
        return 1
    fi

    chmod 600 ~/.ssh/id_ed25519

    cat >> ~/.ssh/config <<SSHEOF
Host ${PUSHGATEWAY_SSH_HOST}
  HostName ${PUSHGATEWAY_SSH_IP}
  User ${PUSHGATEWAY_SSH_USER}
  StrictHostKeyChecking accept-new
SSHEOF
    chmod 600 ~/.ssh/config
    trap 'rm -f ~/.ssh/id_ed25519' EXIT
}
