#!/usr/bin/env bash
# SPDX-FileCopyrightText: 2026 Mattia Egloff <mattia.egloff@pm.me>
#
# SPDX-License-Identifier: GPL-3.0-or-later

# Shared repo detection for just recipes.
# Source this file, then call resolve_repo / repo_dir / repo_toolchain.

set -euo pipefail

# Workspace root. Determined by walking up from $PWD looking for the
# CLAUDE.md + scripts/scripts/resolve-repo.sh marker pair. This is
# portable across bash and zsh — the previous `${BASH_SOURCE[0]}`
# approach silently produced "/" under zsh (where the parameter is
# unset), which then propagated to gitlab_repo_dir and made
# `just gitlab mr-create vauchi-platform-swift` fail in any session
# where the user had `source`d this file from their interactive zsh.
_find_workspace_root() {
    local d="$PWD"
    while [[ "$d" != "/" && -n "$d" ]]; do
        if [[ -f "$d/CLAUDE.md" && -f "$d/scripts/scripts/resolve-repo.sh" ]]; then
            echo "$d"
            return 0
        fi
        d="$(dirname "$d")"
    done
    return 1
}
WORKSPACE_ROOT="$(_find_workspace_root)" || {
    echo "ERROR: could not find vauchi workspace root from PWD=$PWD" >&2
    echo "Run 'just' / source this script from inside the workspace tree." >&2
    # shellcheck disable=SC2317  # the exit branch is reachable when this
    # script is executed (rather than sourced) — `return` fails outside a
    # function/sourced script and the `|| exit 1` then fires.
    return 1 2>/dev/null || exit 1
}

# ── Registry ────────────────────────────────────────────────────────
# Format: name:dir:toolchain
# "dir" is relative to WORKSPACE_ROOT
REPO_REGISTRY=(
    "root:.:none"
    "core:core:rust"
    "cli:cli:rust"
    "relay:relay:rust"
    "ohttp-relay:ohttp-relay:rust"
    "tui:tui:rust"
    "e2e:e2e:rust"
    "android:android:gradle"
    "ios:ios:xcode"
    "docs:docs:mkdocs"
    "locales:locales:python"
    "themes:themes:python"
    "features:features:gherkin"
    "website:website:html"
    "scripts:scripts:shell"
    "_private:_private:none"
    "gitlab-profile:gitlab-profile:none"
    "github-profile:github-profile:none"
    "macos:macos:xcode"
    "windows:windows:dotnet"
    "linux-gtk:linux-gtk:rust"
    "linux-qt:linux-qt:cmake"
    "web-demo:web-demo:npm"
    "assets:assets:none"
    "vauchi-platform-swift:vauchi-platform-swift:swift"
    "vauchi-platform-kotlin:vauchi-platform-kotlin:gradle"
)

# ── Which repos support which operations ────────────────────────────
REPOS_BUILD="core cli relay ohttp-relay tui e2e android ios docs linux-gtk macos windows linux-qt web-demo"
REPOS_TEST="core cli relay ohttp-relay tui e2e android ios docs linux-gtk macos windows linux-qt web-demo"
REPOS_FMT="core cli relay ohttp-relay tui e2e ios linux-gtk"
REPOS_LINT="core cli relay ohttp-relay tui e2e android ios docs locales themes features scripts linux-gtk macos"
REPOS_FIX="core cli relay ohttp-relay tui e2e ios linux-gtk"
REPOS_COVERAGE="core cli relay ohttp-relay tui e2e ios android linux-gtk"
REPOS_BENCH="core relay"

# ── Functions ───────────────────────────────────────────────────────

# Get the directory for a repo name (absolute path)
repo_dir() {
    local name="${1:?repo_dir requires a repo name argument}"
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

# List repo directories by toolchain (e.g., repos_by_toolchain rust → "core cli relay ...")
# Returns space-separated directory names for use in for-loops.
repos_by_toolchain() {
    local toolchain="${1:?repos_by_toolchain requires a toolchain argument (rust, node, kotlin, swift, none)}"
    local dirs=""
    for entry in "${REPO_REGISTRY[@]}"; do
        IFS=: read -r n d t <<< "$entry"
        if [[ "$t" == "$toolchain" && "$d" != "." ]]; then
            dirs="${dirs:+$dirs }$d"
        fi
    done
    echo "$dirs"
}

# Get the toolchain for a repo name
repo_toolchain() {
    local name="${1:?repo_toolchain requires a repo name argument}"
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

# Extra cargo features needed when running tests for a repo.
# Returns empty string if no extra features are needed.
repo_test_features() {
    local name="${1:?repo_test_features requires a repo name argument}"
    case "$name" in
        core) echo "--features vauchi-core/testing" ;;
        *)    echo "" ;;
    esac
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
    # Check if we're exactly at workspace root (the "root:.:none" entry)
    if [[ "$cwd" == "$WORKSPACE_ROOT" ]]; then
        echo "root"
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
        build)    allowed="$REPOS_BUILD" ;;
        test)     allowed="$REPOS_TEST" ;;
        fmt)      allowed="$REPOS_FMT" ;;
        lint)     allowed="$REPOS_LINT" ;;
        fix)      allowed="$REPOS_FIX" ;;
        coverage) allowed="$REPOS_COVERAGE" ;;
        bench)    allowed="$REPOS_BENCH" ;;
        *)        allowed="$REPOS_BUILD" ;;
    esac

    # Explicit "all"
    if [[ "$arg" == "all" ]]; then
        echo "$allowed"
        return 0
    fi

    # Explicit repo name
    if [[ -n "$arg" ]]; then
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
        if echo " $allowed " | grep -q " $detected "; then
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

# ── GitLab helpers ──────────────────────────────────────────────────

# Map directory name to GitLab project name.
# Most are identity (core → core), with exceptions listed below.
_dir_to_gitlab_name() {
    local name="$1"
    case "$name" in
        _private)                echo "private" ;;
        root|.)                  echo "vauchi" ;;
        *)                       echo "$name" ;;
    esac
}

# Resolve a repo name to a full GitLab project path (namespace/project).
# Most repos are under the vauchi group; exceptions listed below.
resolve_gitlab_project() {
    local name
    name=$(_dir_to_gitlab_name "${1:-}")
    case "$name" in
        drift-detector|markdown-plan)   echo "megloff1/$name" ;;
        *)                              echo "vauchi/$name" ;;
    esac
}

# Resolve repo arg to a single GitLab project name.
# Unlike resolve_repo (which returns multiple), this returns exactly one.
resolve_gitlab_repo() {
    local arg="${1:-}"

    # Explicit name
    if [[ -n "$arg" ]]; then
        _dir_to_gitlab_name "$arg"
        return 0
    fi

    # Detect from pwd
    local detected
    if detected=$(_detect_repo_from_pwd); then
        _dir_to_gitlab_name "$detected"
        return 0
    fi

    # At workspace root — ambiguous for GitLab ops
    echo "ERROR: specify a repo (cannot target all repos for GitLab operations)" >&2
    return 1
}

# Get the working directory for a repo (for git branch detection etc.)
gitlab_repo_dir() {
    local arg="${1:-}"

    if [[ -n "$arg" ]]; then
        # Map to first matching directory
        case "$arg" in
            root|vauchi)  echo "$WORKSPACE_ROOT" ;;
            *)            echo "$WORKSPACE_ROOT/$arg" ;;
        esac
        return 0
    fi

    # Detect from pwd
    local detected
    if detected=$(_detect_repo_from_pwd); then
        repo_dir "$detected"
        return 0
    fi

    echo "$WORKSPACE_ROOT"
}
