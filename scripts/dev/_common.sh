#!/bin/bash
# SPDX-FileCopyrightText: 2026 Mattia Egloff <mattia.egloff@pm.me>
#
# SPDX-License-Identifier: GPL-3.0-or-later
# Common variables and utilities for dev scripts
#
# Source this file at the beginning of dev scripts:
#   source "$(dirname "${BASH_SOURCE[0]}")/_common.sh"

# Determine workspace root and code directory
# This file is in _dev-tools/scripts/dev/
_COMMON_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$_COMMON_DIR/../../.." && pwd)"
export PROJECT_ROOT
export CODE_DIR="$PROJECT_ROOT/code"

# Directories for test data and caches
# ./tmp - ephemeral test data, cleaned before test runs
# ./cache - persistent caches (AVDs, simulator data), cleaned by cleanup command
export TMP_DIR="$PROJECT_ROOT/tmp"
export CACHE_DIR="$PROJECT_ROOT/cache"

# Subdirectories
export ANDROID_CACHE_DIR="$CACHE_DIR/android"
export ANDROID_AVD_DIR="$ANDROID_CACHE_DIR/avd"
export IOS_CACHE_DIR="$CACHE_DIR/ios"
export IOS_DERIVED_DATA_DIR="$IOS_CACHE_DIR/DerivedData"

# Test data directories (in tmp, cleaned before runs)
export TEST_DATA_DIR="$TMP_DIR/test-data"

# Platform directories
export ANDROID_DIR="$PROJECT_ROOT/android"
export IOS_DIR="$PROJECT_ROOT/ios"

# Ensure directories exist
ensure_dirs() {
    mkdir -p "$TMP_DIR" "$CACHE_DIR"
    mkdir -p "$ANDROID_AVD_DIR" "$IOS_DERIVED_DATA_DIR"
    mkdir -p "$TEST_DATA_DIR"
}

# Clean tmp directory (call before test runs)
clean_tmp() {
    if [ -d "$TMP_DIR" ]; then
        echo "Cleaning tmp directory..."
        rm -rf "${TMP_DIR:?}"/*
        # Preserve .gitignore
        echo '# Ignore everything in tmp except this file
*
!.gitignore' > "$TMP_DIR/.gitignore"
    fi
    mkdir -p "$TEST_DATA_DIR"
}

# Clean cache directory (call from cleanup commands)
clean_cache() {
    if [ -d "$CACHE_DIR" ]; then
        echo "Cleaning cache directory..."
        rm -rf "${CACHE_DIR:?}"/*
        # Preserve .gitignore
        echo '# Ignore everything in cache except this file
*
!.gitignore' > "$CACHE_DIR/.gitignore"
    fi
    mkdir -p "$ANDROID_AVD_DIR" "$IOS_DERIVED_DATA_DIR"
}

# Clean everything
clean_all() {
    clean_tmp
    clean_cache
}

# Colors for output
export RED='\033[0;31m'
export GREEN='\033[0;32m'
export YELLOW='\033[1;33m'
export BLUE='\033[0;34m'
export NC='\033[0m' # No Color

# Print colored status
print_status() {
    local color="$1"
    local message="$2"
    echo -e "${color}${message}${NC}"
}

print_info() { print_status "$BLUE" "$1"; }
print_success() { print_status "$GREEN" "$1"; }
print_warning() { print_status "$YELLOW" "$1"; }
print_error() { print_status "$RED" "$1"; }

# OS Detection
detect_os() {
    case "$(uname -s)" in
        Darwin)
            echo "macos"
            ;;
        Linux)
            echo "linux"
            ;;
        MINGW*|MSYS*|CYGWIN*|Windows_NT)
            echo "windows"
            ;;
        *)
            echo "unknown"
            ;;
    esac
}

OS_TYPE=$(detect_os)
export OS_TYPE
IS_MACOS=$([[ "$OS_TYPE" == "macos" ]] && echo true || echo false)
export IS_MACOS
IS_LINUX=$([[ "$OS_TYPE" == "linux" ]] && echo true || echo false)
export IS_LINUX
IS_WINDOWS=$([[ "$OS_TYPE" == "windows" ]] && echo true || echo false)
export IS_WINDOWS

# Get local IP address for network connections
get_local_ip() {
    case "$OS_TYPE" in
        macos)
            # Get primary interface IP (en0 for Wi-Fi, en1 for Ethernet)
            ipconfig getifaddr en0 2>/dev/null || ipconfig getifaddr en1 2>/dev/null || echo "127.0.0.1"
            ;;
        linux)
            hostname -I 2>/dev/null | awk '{print $1}' || ip route get 1 2>/dev/null | awk '{print $7}' || echo "127.0.0.1"
            ;;
        windows)
            # WSL or Git Bash
            ip route get 1 2>/dev/null | awk '{print $7}' || hostname -I 2>/dev/null | awk '{print $1}' || echo "127.0.0.1"
            ;;
        *)
            echo "127.0.0.1"
            ;;
    esac
}

# Print connection info for remote development
print_connection_info() {
    local service_name="$1"
    local port="$2"
    local local_ip
    local_ip=$(get_local_ip)

    echo ""
    print_info "═══════════════════════════════════════════════════════════════"
    print_info "  Remote Connection Info for $service_name"
    print_info "═══════════════════════════════════════════════════════════════"
    echo ""
    echo "  Local IP Address: $local_ip"
    if [ -n "$port" ]; then
        echo "  Port: $port"
        echo "  Full Address: $local_ip:$port"
    fi
    echo ""
    echo "  Ensure your firewall allows incoming connections on this port."
    echo ""
    print_info "═══════════════════════════════════════════════════════════════"
    echo ""
}
