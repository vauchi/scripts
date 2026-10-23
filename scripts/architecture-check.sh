#!/usr/bin/env bash
# SPDX-FileCopyrightText: 2026 Mattia Egloff <mattia.egloff@pm.me>
# SPDX-License-Identifier: GPL-3.0-or-later

set -euo pipefail
die() { echo "VRS06: $*" >&2; exit 2; }
[[ $# -ge 1 && $# -le 3 ]] || die 'usage: architecture-check.sh ROOT [check|scan|advisory] [BASE_REF]'
source_root=$(cd "$1" && pwd) || die 'source root is missing'
mode=${2:-check}
base_ref=${3:-origin/main}
scripts_root=$(cd "$(dirname "$0")/.." && pwd)
tool_root="$scripts_root/tools/architecture-check"
target_dir="$tool_root/target"
binary="$target_dir/release/vauchi-architecture-check"
policy="$source_root/.architecture-policy.json"
baseline="$source_root/.architecture-baseline.json"

if [[ "$mode" == advisory ]]; then
    if [[ ! -x "$binary" || ! -f "$policy" || ! -f "$baseline" ]]; then
        echo 'VRS06 advisory: run just architecture-gate to build/check the architecture baseline.' >&2
        exit 0
    fi
    timer=$(command -v timeout || command -v gtimeout || true)
    if [[ -z "$timer" ]]; then
        echo 'VRS06 advisory: bounded checker unavailable; run just architecture-gate.' >&2
        exit 0
    fi
    status=0
    VAUCHI_ARCHITECTURE_GENERATED_DIR="$target_dir/generated" \
        "$timer" 0.8 "$binary" check "$source_root" "$policy" "$baseline" >&2 || status=$?
    if [[ "$status" != 0 ]]; then
        echo 'VRS06 advisory: run just architecture-gate for a fresh, complete check.' >&2
    fi
    exit 0
fi

[[ "$mode" == check || "$mode" == scan ]] || die "unknown mode: $mode"
for tool in cargo rustc git; do
    command -v "$tool" >/dev/null || die "missing required tool: $tool"
done
[[ -f "$tool_root/Cargo.toml" && -f "$tool_root/Cargo.lock" ]] || die 'analyzer source/lockfile missing'
if [[ "$mode" == check ]]; then
    [[ -f "$policy" && -f "$baseline" ]] || die 'policy or baseline missing'
    git -C "$source_root" rev-parse --verify "$base_ref^{commit}" >/dev/null 2>&1 || die "missing comparison ref: $base_ref"
fi
scratch=$(mktemp -d)
trap 'rm -rf "$scratch"' EXIT
cargo build --quiet --locked --release -j 8 --manifest-path "$tool_root/Cargo.toml" \
    --target-dir "$target_dir" || die 'analyzer build failed'
[[ -x "$binary" ]] || die 'analyzer executable missing after build'
if [[ -f "$source_root/Cargo.toml" ]]; then
    cargo metadata --no-deps --format-version 1 --locked --manifest-path "$source_root/Cargo.toml" > "$scratch/cargo-metadata.json" || die 'Cargo metadata failed'
    mkdir -p "$target_dir/generated"
    cp "$scratch/cargo-metadata.json" "$target_dir/generated/cargo-metadata.json"
fi

if [[ -d "$source_root/vauchi-app/src" ]]; then
    [[ -f "$source_root/vauchi-app/build.rs" ]] || die 'app source generator missing'
    rustc --edition=2024 "$source_root/vauchi-app/build.rs" -o "$scratch/generate" || die 'source generator did not compile'
    (cd "$source_root/vauchi-app" && OUT_DIR="$scratch" "$scratch/generate" > "$scratch/generator.log" 2>&1) || die 'source generator failed'
    [[ -f "$scratch/bundled_locale.rs" ]] || die 'generated locale source missing'
    mkdir -p "$target_dir/generated"
    cp "$scratch/bundled_locale.rs" "$target_dir/generated/bundled_locale.rs"
fi
export VAUCHI_ARCHITECTURE_GENERATED_DIR="$scratch"
if [[ "$mode" == scan ]]; then
    "$binary" scan "$source_root"
    exit $?
fi

if git -C "$source_root" cat-file -e "$base_ref:.architecture-baseline.json" 2>/dev/null; then
    git -C "$source_root" show "$base_ref:.architecture-baseline.json" > "$scratch/previous-baseline.json"
    git -C "$source_root" show "$base_ref:.architecture-policy.json" > "$scratch/previous-policy.json" || die 'comparison policy missing'
    "$binary" check "$source_root" "$policy" "$baseline" "$scratch/previous-baseline.json" "$scratch/previous-policy.json"
else
    if git -C "$source_root" cat-file -e "$base_ref:.architecture-policy.json" 2>/dev/null; then
        die 'comparison baseline missing despite an existing policy'
    fi
    echo 'VRS06: initial baseline introduction; policy and exceptions require MR review.' >&2
    "$binary" check "$source_root" "$policy" "$baseline"
fi
