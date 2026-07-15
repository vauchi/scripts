#!/usr/bin/env bash
# SPDX-FileCopyrightText: 2026 Mattia Egloff <mattia.egloff@pm.me>
#
# SPDX-License-Identifier: GPL-3.0-or-later
#
# Common shell helpers for Vauchi scripts.
#
# Source this file at the start of Bash scripts instead of redefining
# logging, colours, and fatal-error handling. Callers must set
# `set -euo pipefail` themselves; this library does not override shell
# options so that callers retain their own choices. Safe to source
# multiple times (idempotent guards below).
#
# Usage:
#   source "$(dirname "${BASH_SOURCE[0]}")/../lib/common.sh"
#   log_info "starting"
#   die "fatal condition" 2

# ── Idempotency guards ─────────────────────────────────────────────

if [[ -n "${VAUCHI_COMMON_SH_LOADED:-}" ]]; then
    return 0
fi
VAUCHI_COMMON_SH_LOADED=1

# ── Colours ────────────────────────────────────────────────────────

if [[ -t 2 ]]; then
    export VAUCHI_RED='\033[0;31m'
    export VAUCHI_GREEN='\033[0;32m'
    export VAUCHI_YELLOW='\033[1;33m'
    export VAUCHI_BLUE='\033[0;34m'
    export VAUCHI_BOLD='\033[1m'
    export VAUCHI_NC='\033[0m'
else
    export VAUCHI_RED=''
    export VAUCHI_GREEN=''
    export VAUCHI_YELLOW=''
    export VAUCHI_BLUE=''
    export VAUCHI_BOLD=''
    export VAUCHI_NC=''
fi

# ── Logging ────────────────────────────────────────────────────────

log_info()    { printf '%b[INFO]%b %s\n' "$VAUCHI_BLUE"   "$VAUCHI_NC" "$*" >&2; }
log_success() { printf '%b[OK]%b %s\n'   "$VAUCHI_GREEN"  "$VAUCHI_NC" "$*" >&2; }
log_warn()    { printf '%b[WARN]%b %s\n' "$VAUCHI_YELLOW" "$VAUCHI_NC" "$*" >&2; }
log_error()   { printf '%b[ERROR]%b %s\n' "$VAUCHI_RED"    "$VAUCHI_NC" "$*" >&2; }

# ── Fatal errors ───────────────────────────────────────────────────

# Print an error message and exit. Default exit code is 1.
die() {
    local msg="${1:-fatal error}"
    local code="${2:-1}"
    log_error "$msg"
    exit "$code"
}

# Require a command to exist; otherwise die with a helpful message.
require_cmd() {
    local cmd="${1:?require_cmd needs a command name}"
    if ! command -v "$cmd" >/dev/null 2>&1; then
        die "required command not found: $cmd"
    fi
}

# Require a non-empty variable; otherwise die.
require_env() {
    local name="${1:?require_env needs a variable name}"
    if [[ -z "${!name:-}" ]]; then
        die "required environment variable not set: $name"
    fi
}
