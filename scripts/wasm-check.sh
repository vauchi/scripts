#!/usr/bin/env bash
# SPDX-FileCopyrightText: 2026 Mattia Egloff <mattia.egloff@pm.me>
# SPDX-License-Identifier: GPL-3.0-or-later

# The Rust half of a repo whose crate lives in wasm/ beside an npm root
# (web-demo); CI's build:wasm runs the same locked tests (private#856).
set -euo pipefail
repo=${1:?Usage: wasm-check.sh REPO}
crate="$repo/wasm"
[[ -f "$crate/Cargo.toml" ]] || { echo "Missing wasm/Cargo.toml: $repo" >&2; exit 1; }
command -v cargo >/dev/null || { echo "Required tool missing: cargo" >&2; exit 1; }
cd "$crate"
cargo fmt --check
cargo clippy --all-targets --locked -- -D warnings
cargo test --locked
