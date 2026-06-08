#!/usr/bin/env bash
# SPDX-FileCopyrightText: 2026 Mattia Egloff <mattia.egloff@pm.me>
#
# SPDX-License-Identifier: GPL-3.0-or-later
#
# SHA-based binary cache for E2E test binaries.
# Builds relay + CLI only when source has changed.

set -euo pipefail

WORKSPACE_ROOT="$(cd "$(dirname "$0")/../../.." && pwd)"
BIN_DIR="${E2E_BIN_DIR:-${WORKSPACE_ROOT}/target/e2e-bin}"

mkdir -p "$BIN_DIR"

# Compute a SHA for a repo directory.
# Uses git HEAD + dirty-state suffix to bust cache on uncommitted changes.
# Falls back to hashing src/*.rs files when not in a git repo.
repo_sha() {
    local repo_dir="$1"
    local head_sha
    if head_sha=$(git -C "$repo_dir" rev-parse HEAD 2>/dev/null); then
        # Append "-dirty" suffix when working tree has uncommitted changes
        if ! git -C "$repo_dir" diff-index --quiet HEAD -- 2>/dev/null; then
            # Include diff hash so different dirty states bust the cache
            local diff_hash
            diff_hash=$(git -C "$repo_dir" diff HEAD -- | shasum -a 256 | cut -d' ' -f1)
            echo "${head_sha}-dirty-${diff_hash:0:12}"
        else
            echo "$head_sha"
        fi
        return
    fi
    # Fallback: hash all .rs files under src/
    find "$repo_dir/src" -name '*.rs' -print0 | sort -z | xargs -0 shasum -a 256 | shasum -a 256 | cut -d' ' -f1
}

# Build a binary if the SHA has changed.
# Args: repo_dir binary_name cargo_extra_args...
build_if_changed() {
    local repo_dir="$1"
    local binary_name="$2"
    shift 2
    local extra_args=("$@")

    local sha
    sha="$(repo_sha "$repo_dir")"
    local sha_file="$BIN_DIR/.${binary_name}.sha"

    if [[ -f "$sha_file" ]] && [[ -f "$BIN_DIR/$binary_name" ]]; then
        local cached_sha
        cached_sha="$(cat "$sha_file")"
        if [[ "$cached_sha" == "$sha" ]]; then
            echo "  [cached] $binary_name (SHA unchanged)"
            return 0
        fi
    fi

    echo "  [build]  $binary_name ..."
    (cd "$repo_dir" && cargo build --release --target-dir "$WORKSPACE_ROOT/target" "${extra_args[@]}")

    # Copy binary to cache dir
    local built_path="$WORKSPACE_ROOT/target/release/$binary_name"
    if [[ ! -f "$built_path" ]]; then
        echo "ERROR: Expected binary not found at $built_path" >&2
        exit 1
    fi
    cp "$built_path" "$BIN_DIR/$binary_name"
    echo "$sha" > "$sha_file"
    echo "  [done]   $binary_name"
}

echo "═══ E2E Binary Build (SHA cache) ═══"
echo "  Cache dir: $BIN_DIR"
echo ""

# Build CLI (no secure-storage for e2e — keys don't persist between invocations)
build_if_changed "$WORKSPACE_ROOT/cli" "vauchi" --no-default-features

build_if_changed "$WORKSPACE_ROOT/relay" "vauchi-relay"

echo ""
echo "Binaries ready in $BIN_DIR"
