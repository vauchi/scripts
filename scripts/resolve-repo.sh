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
    # Vauchi worktrees keep the full repo set under .worktrees/<name>/.
    # Detect that first so we don't walk up to the main workspace root.
    if [[ "$d" =~ /\.worktrees/[^/]+ ]]; then
        printf '%s\n' "$d" | sed -E 's#(/.worktrees/[^/]+).*#\1#'
        return 0
    fi
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
# The canonical registry is root/repos.toml. Load it at runtime so just,
# CI, and shell helpers share a single source of truth. Falls back to the
# hardcoded array below if repos.toml or repo-registry.py is missing.
# Format: name:dir:toolchain ("dir" is relative to WORKSPACE_ROOT).
_load_repo_registry() {
    local registry_helper="$WORKSPACE_ROOT/scripts/scripts/lib/repo-registry.py"
    if [[ ! -x "$registry_helper" ]]; then
        registry_helper="$WORKSPACE_ROOT/root/scripts/scripts/lib/repo-registry.py"
    fi
    local repos_toml="$WORKSPACE_ROOT/repos.toml"
    [[ -f "$repos_toml" ]] || repos_toml="$WORKSPACE_ROOT/root/repos.toml"
    if [[ -x "$registry_helper" && -f "$repos_toml" ]]; then
        (cd "$(dirname "$repos_toml")" && python3 "$registry_helper" list) 2>/dev/null
        return 0
    fi
    return 1
}

REPO_REGISTRY=()
_repo_registry_tmp=$(mktemp)
if _load_repo_registry > "$_repo_registry_tmp"; then
    while IFS= read -r line; do
        [[ -n "$line" ]] || continue
        REPO_REGISTRY+=("$line")
    done < "$_repo_registry_tmp"
fi
rm -f "$_repo_registry_tmp"
if [[ ${#REPO_REGISTRY[@]} -eq 0 ]]; then
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
        "docs:docs:mdbook"
        "spec:spec:mdbook"
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
        "contract:contract:rust"
        "linux-hw:linux-hw:rust"
        "linux-qt:linux-qt:cmake"
        "web-demo:web-demo:npm"
        "assets:assets:none"
        "vauchi-platform-swift:vauchi-platform-swift:swift"
        "vauchi-platform-kotlin:vauchi-platform-kotlin:gradle"
    )
fi

# ── Which repos support which operations ────────────────────────────
# The registry (repos.toml, `ops = [...]` per repository) says which repos
# each recipe accepts; the literals below are the fallback for a checkout
# without the registry, as for the table above (private#1013).
_registry_ops() {
    local helper="$WORKSPACE_ROOT/scripts/scripts/lib/repo-registry.py"
    [[ -x "$helper" ]] || helper="$WORKSPACE_ROOT/root/scripts/scripts/lib/repo-registry.py"
    local toml="$WORKSPACE_ROOT/repos.toml"
    [[ -f "$toml" ]] || toml="$WORKSPACE_ROOT/root/repos.toml"
    if [[ -x "$helper" && -f "$toml" ]]; then
        (cd "$(dirname "$toml")" && python3 "$helper" ops "$1") 2>/dev/null
    fi
}
REPOS_BUILD="$(_registry_ops build)"
REPOS_TEST="$(_registry_ops test)"
REPOS_FMT="$(_registry_ops fmt)"
REPOS_LINT="$(_registry_ops lint)"
REPOS_FIX="$(_registry_ops fix)"
REPOS_COVERAGE="$(_registry_ops coverage)"
REPOS_BENCH="$(_registry_ops bench)"
if [[ -z "$REPOS_BUILD" ]]; then
    REPOS_BUILD="core cli relay ohttp-relay tui e2e android ios docs spec linux-gtk macos windows linux-qt web-demo contract linux-hw"
    REPOS_TEST="core cli relay ohttp-relay tui e2e android ios docs linux-gtk macos windows linux-qt web-demo contract linux-hw"
    REPOS_FMT="core cli relay ohttp-relay tui e2e ios linux-gtk contract linux-hw"
    REPOS_LINT="core cli relay ohttp-relay tui e2e android ios docs spec locales themes features scripts linux-gtk macos contract linux-hw"
    REPOS_FIX="core cli relay ohttp-relay tui e2e ios linux-gtk contract linux-hw"
    REPOS_COVERAGE="core cli relay ohttp-relay tui e2e ios android linux-gtk contract linux-hw"
    REPOS_BENCH="core relay"
fi

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
        # `test-kdf` weakens Argon2id parameters (8 MB / 1 iteration vs.
        # 64 MB / 3 iterations) for ~5x faster KDF-bound tests. Already
        # used by core CI (see core/.gitlab-ci.yml). Enabling it locally
        # too keeps `just test core` and CI consistent.
        # `vauchi-app/testing` is its own flag: `vauchi-core/testing` does
        # not set `cfg(feature = "testing")` inside vauchi-app's tests, so
        # without it 14 gated tests compiled out and ran nowhere.
        # `vauchi-app/network-http` matches core CI's test:app job; without
        # it `just test-name <p> core vauchi-app it` fails to compile
        # (schedule_wakeup_tests calls the HTTP-gated set_next_sync_allowed).
        core) echo "--features vauchi-core/testing,vauchi-core/test-kdf,vauchi-app/testing,vauchi-app/network-http" ;;
        # `test-utils` gates the shared state constructors that
        # router_integration, server_lifecycle and client_ip need. Cargo
        # silently skips a target whose required-features are absent, so
        # without this `just test ohttp-relay` runs 40 of 86 tests and
        # reports success.
        ohttp-relay) echo "--features test-utils" ;;
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
#
# Workspace-root clones are commonly named `vauchi`, `vauchi-1`,
# `vauchi-foo`, etc. (one per parallel clone). All map to the same
# GitLab project `vauchi/vauchi`. Without this mapping, multi-clone
# users get spurious queries against `vauchi/vauchi-N` (404) from
# `_add_sibling_mr` in the `mr-create` auto-link pass.
_dir_to_gitlab_name() {
    local name="$1"
    case "$name" in
        _private)
            echo "private" ;;
        vauchi-platform-swift|vauchi-platform-kotlin)
            echo "$name" ;;
        root|.|vauchi|vauchi-*)
            echo "vauchi" ;;
        # ADR-078 rename (private#1029): the directories keep their names
        # until the registry moves, and GitLab follows a moved project's
        # old path for GET only.
        linux-gtk)
            echo "gtk-display" ;;
        linux-qt)
            echo "qt-display" ;;
        # windows was renamed to windows-app on 2026-11-22 (private#1234).
        windows)
            echo "windows-app" ;;
        *)
            echo "$name" ;;
    esac
}

# The directory the registry gives a repo name, relative to WORKSPACE_ROOT.
_registry_dir() {
    local entry rest
    for entry in "${REPO_REGISTRY[@]}"; do
        [[ "${entry%%:*}" == "$1" ]] || continue
        rest=${entry#*:}
        echo "${rest%%:*}"
        return 0
    done
    return 1
}

# Resolve a repo name to a full GitLab project path (namespace/project).
# Repos cloned under utils/ live in the vauchi/utils subgroup (tools and
# forks, private#1034); the rest are directly under vauchi.
resolve_gitlab_project() {
    local name
    # Route through resolve_gitlab_repo so an empty arg gets pwd detection
    # (at workspace root this yields "vauchi", not the empty name that
    # _dir_to_gitlab_name "" produced — which made the project "vauchi/").
    name=$(resolve_gitlab_repo "${1:-}") || return 1
    case "$(_registry_dir "$name" || true)" in
        utils/*) echo "vauchi/utils/$name" ;;
        *)       echo "vauchi/$name" ;;
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
        # Map to first matching directory. In a worktree the root repo is a
        # sibling of the other repos (workspace-root/root/), whereas in the
        # main workspace it lives at the workspace root.
        local repo_path
        case "$arg" in
            root|vauchi)
                if [[ -e "$WORKSPACE_ROOT/.git" ]]; then
                    repo_path="$WORKSPACE_ROOT"
                else
                    repo_path="$WORKSPACE_ROOT/root"
                fi
                ;;
            *)            repo_path="$WORKSPACE_ROOT/$(_registry_dir "$arg" || echo "$arg")" ;;
        esac
        # Worktree groups use sibling symlinks. Passing a logical symlink path
        # to `git -C` makes hooks inherit the coordinator worktree as their
        # repository context, so stale-base checks can inspect the wrong tree.
        # Resolve existing directories physically before any Git operation.
        if [[ -d "$repo_path" ]]; then
            (cd "$repo_path" && pwd -P)
        else
            echo "$repo_path"
        fi
        return 0
    fi

    # Detect from pwd
    local detected
    if detected=$(_detect_repo_from_pwd); then
        # Detection names the workspace root "root", which the registry
        # does not list; the explicit branch above maps it.
        gitlab_repo_dir "$detected"
        return 0
    fi

    echo "$WORKSPACE_ROOT"
}
