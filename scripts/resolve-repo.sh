#!/usr/bin/env bash
# SPDX-FileCopyrightText: 2026 Mattia Egloff <mattia.egloff@pm.me>
#
# SPDX-License-Identifier: GPL-3.0-or-later

# Shared repo detection for just recipes.
# Source this file, then call resolve_repo / repo_dir / repo_toolchain.

set -euo pipefail

# Workspace root (parent of scripts/)
WORKSPACE_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"

# ── Registry ────────────────────────────────────────────────────────
# Format: name:dir:toolchain
# "dir" is relative to WORKSPACE_ROOT
REPO_REGISTRY=(
    "core:core:rust"
    "cli:cli:rust"
    "relay:relay:rust"
    "tui:tui:rust"
    "e2e:e2e:rust"
    "desktop-rust:desktop/src-tauri:rust"
    "desktop-ui:desktop/ui:npm"
    "android:android:gradle"
    "ios:ios:xcode"
    "docs:docs:mkdocs"
    "locales:locales:python"
    "themes:themes:python"
    "features:features:gherkin"
    "website:website:html"
    "scripts:scripts:shell"
)

# "desktop" is a virtual name that expands to desktop-rust + desktop-ui
DESKTOP_PARTS="desktop-rust desktop-ui"

# ── Which repos support which operations ────────────────────────────
REPOS_BUILD="core cli relay tui e2e desktop-rust desktop-ui android ios docs"
REPOS_TEST="core cli relay tui e2e desktop-rust desktop-ui android ios docs"
REPOS_FMT="core cli relay tui e2e desktop-rust desktop-ui ios"
REPOS_LINT="core cli relay tui e2e desktop-rust desktop-ui android ios docs locales themes features scripts"
REPOS_FIX="core cli relay tui e2e desktop-rust desktop-ui ios"

# ── Functions ───────────────────────────────────────────────────────

# Get the directory for a repo name (absolute path)
repo_dir() {
    local name="$1"
    for entry in "${REPO_REGISTRY[@]}"; do
        IFS=: read -r n d t <<< "$entry"
        if [[ "$n" == "$name" ]]; then
            echo "$WORKSPACE_ROOT/$d"
            return 0
        fi
    done
    echo "ERROR: unknown repo '$name'" >&2
    return 1
}

# Get the toolchain for a repo name
repo_toolchain() {
    local name="$1"
    for entry in "${REPO_REGISTRY[@]}"; do
        IFS=: read -r n d t <<< "$entry"
        if [[ "$n" == "$name" ]]; then
            echo "$t"
            return 0
        fi
    done
    echo "ERROR: unknown repo '$name'" >&2
    return 1
}

# Detect repo from current working directory
_detect_repo_from_pwd() {
    local cwd="$PWD"
    # Check if we're inside a known repo directory
    for entry in "${REPO_REGISTRY[@]}"; do
        IFS=: read -r n d t <<< "$entry"
        local full="$WORKSPACE_ROOT/$d"
        if [[ "$cwd" == "$full" || "$cwd" == "$full"/* ]]; then
            echo "$n"
            return 0
        fi
    done
    # Check if we're in desktop/ (but not src-tauri/ or ui/ specifically)
    if [[ "$cwd" == "$WORKSPACE_ROOT/desktop" || "$cwd" == "$WORKSPACE_ROOT/desktop/"* ]]; then
        echo "desktop"
        return 0
    fi
    return 1
}

# Resolve repo argument to a space-separated list of repo names.
# Args: $1 = user-provided repo arg (may be empty), $2 = operation (build|test|fmt|lint|fix)
resolve_repo() {
    local arg="${1:-}"
    local operation="${2:-build}"

    # Get the allowed repos for this operation
    local allowed
    case "$operation" in
        build) allowed="$REPOS_BUILD" ;;
        test)  allowed="$REPOS_TEST" ;;
        fmt)   allowed="$REPOS_FMT" ;;
        lint)  allowed="$REPOS_LINT" ;;
        fix)   allowed="$REPOS_FIX" ;;
        *)     allowed="$REPOS_BUILD" ;;
    esac

    # Explicit "all"
    if [[ "$arg" == "all" ]]; then
        echo "$allowed"
        return 0
    fi

    # Explicit repo name
    if [[ -n "$arg" ]]; then
        # Expand "desktop" virtual name
        if [[ "$arg" == "desktop" ]]; then
            local result=""
            for part in $DESKTOP_PARTS; do
                if echo " $allowed " | grep -q " $part "; then
                    result="$result $part"
                fi
            done
            echo "${result# }"
            return 0
        fi
        # Validate it's in the allowed list
        if echo " $allowed " | grep -q " $arg "; then
            echo "$arg"
            return 0
        fi
        echo "ERROR: repo '$arg' does not support '$operation'" >&2
        echo "Available: $allowed" >&2
        return 1
    fi

    # No argument: detect from pwd
    local detected
    if detected=$(_detect_repo_from_pwd); then
        # Expand desktop if needed
        if [[ "$detected" == "desktop" ]]; then
            local result=""
            for part in $DESKTOP_PARTS; do
                if echo " $allowed " | grep -q " $part "; then
                    result="$result $part"
                fi
            done
            echo "${result# }"
        elif echo " $allowed " | grep -q " $detected "; then
            echo "$detected"
        else
            echo "ERROR: detected repo '$detected' does not support '$operation'" >&2
            return 1
        fi
        return 0
    fi

    # At workspace root: all
    echo "$allowed"
}
