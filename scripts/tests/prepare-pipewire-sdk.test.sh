#!/usr/bin/env bash
# SPDX-FileCopyrightText: 2026 Mattia Egloff <mattia.egloff@pm.me>
# SPDX-License-Identifier: GPL-3.0-or-later
set -euo pipefail

helper="$(dirname "$0")/../ci/prepare-pipewire-sdk.sh"
scratch=$(mktemp -d)
trap 'rm -rf "$scratch"' EXIT
mkdir -p "$scratch/bin"
cat > "$scratch/bin/apt-get" <<'SH'
#!/bin/sh
set -eu
[ "$1" = download ] || exit 91
[ "${FAIL_DOWNLOAD:-0}" = 0 ] || exit 92
touch sdk.deb
SH
cat > "$scratch/bin/dpkg-deb" <<'SH'
#!/bin/sh
set -eu
[ "$1" = -x ] || exit 93
[ "${FAIL_EXTRACT:-0}" = 0 ] || exit 94
pc="$3/usr/lib/$(gcc -dumpmachine)/pkgconfig"
mkdir -p "$pc"
for name in libpipewire-0.3 libspa-0.2; do
    cat > "$pc/$name.pc" <<EOF
prefix=/usr
libdir=/usr/lib/$(gcc -dumpmachine)
includedir=\${prefix}/include
Name: $name
Description: SDK boundary fixture
Version: ${SDK_VERSION:-1.4.2}
Libs: -L\${libdir} -lpipewire-0.3
Cflags: -I\${includedir}
EOF
done
SH
chmod +x "$scratch/bin/apt-get" "$scratch/bin/dpkg-deb"
export PATH="$scratch/bin:$PATH"
export PKG_CONFIG_PATH="/previous/config"
export LD_LIBRARY_PATH="/previous/libraries"
sdk="$scratch/camera's SDK & files"
bash "$helper" "$sdk"
# shellcheck source=/dev/null
source "$sdk/env.sh"
lib="$sdk/usr/lib/$(gcc -dumpmachine)"
[ "$PKG_CONFIG_PATH" = "$lib/pkgconfig:/previous/config" ]
[ "$LD_LIBRARY_PATH" = "$lib:/previous/libraries" ]
[ "$PIPEWIRE_MODULE_DIR" = "$lib/pipewire-0.3" ]
[ "$SPA_PLUGIN_DIR" = "$lib/spa-0.2" ]
[ "$PIPEWIRE_CONFIG_DIR" = "$sdk/usr/share/pipewire" ]
[ "$(pkg-config --modversion libpipewire-0.3)" = 1.4.2 ]
[ "$(pkg-config --variable=prefix libpipewire-0.3)" = "$sdk/usr" ]
[ "$(pkg-config --variable=libdir libpipewire-0.3)" = "$lib" ]

expect_failure() {
    local name=$1 flag=$2 value=$3
    local target="$scratch/$name"
    mkdir -p "$target"
    printf 'stale environment\n' > "$target/env.sh"
    if env "$flag=$value" bash "$helper" "$target" > "$scratch/error" 2>&1; then
        echo "FAIL: accepted $name" >&2
        exit 1
    fi
    [ ! -e "$target/env.sh" ] || { echo "FAIL: $name left a ready environment" >&2; exit 1; }
}
expect_failure download-failure FAIL_DOWNLOAD 1
expect_failure extraction-failure FAIL_EXTRACT 1
expect_failure unsupported-version SDK_VERSION 0.3.65
echo 'PASS: rootless SDK layout, quoted environment, preserved paths and failure cleanup'
