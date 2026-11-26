#!/usr/bin/env bash
# SPDX-FileCopyrightText: 2026 Mattia Egloff <mattia.egloff@pm.me>
# SPDX-License-Identifier: GPL-3.0-or-later
# Usage: prepare-pipewire-sdk.sh <job-owned-directory>; source its env.sh on success.
set -euo pipefail

sdk_dir=${1:?SDK directory required}
mkdir -p -- "$sdk_dir"
sdk_dir=$(cd "$sdk_dir" && pwd -P)
rm -f "$sdk_dir/env.sh"
mkdir -p "$sdk_dir/downloads"
(
    cd "$sdk_dir/downloads"
    apt-get download libpipewire-0.3-dev libspa-0.2-dev libpipewire-0.3-0t64 \
        libpipewire-0.3-common libpipewire-0.3-modules libspa-0.2-modules
)
for package in "$sdk_dir"/downloads/*.deb; do
    dpkg-deb -x "$package" "$sdk_dir"
done
triplet=$(gcc -dumpmachine)
lib_dir="$sdk_dir/usr/lib/$triplet"
# Relocate only the staged SDK metadata; a global sysroot would also redirect GTK/Qt.
python3 - "$sdk_dir" "$triplet" <<'PY'
import pathlib
import sys
root = pathlib.Path(sys.argv[1])
pc_dir = root / "usr/lib" / sys.argv[2] / "pkgconfig"
for name in ("libpipewire-0.3.pc", "libspa-0.2.pc"):
    path = pc_dir / name
    path.write_text(path.read_text().replace("/usr", str(root / "usr")))
PY
pkg_path="$lib_dir/pkgconfig${PKG_CONFIG_PATH:+:$PKG_CONFIG_PATH}"
PKG_CONFIG_PATH="$pkg_path" pkg-config --atleast-version=0.3.77 libpipewire-0.3
{
    printf 'export PKG_CONFIG_PATH=%q\n' "$pkg_path"
    printf 'export LD_LIBRARY_PATH=%q\n' "$lib_dir${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"
    printf 'export PIPEWIRE_MODULE_DIR=%q\n' "$lib_dir/pipewire-0.3"
    printf 'export SPA_PLUGIN_DIR=%q\n' "$lib_dir/spa-0.2"
    printf 'export PIPEWIRE_CONFIG_DIR=%q\n' "$sdk_dir/usr/share/pipewire"
} > "$sdk_dir/env.sh"
