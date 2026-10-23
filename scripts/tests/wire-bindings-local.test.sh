#!/usr/bin/env bash
# SPDX-FileCopyrightText: 2026 Mattia Egloff <mattia.egloff@pm.me>
# SPDX-License-Identifier: GPL-3.0-or-later

set -euo pipefail

ROOT=$(cd "$(dirname "$0")/../.." && pwd)
SCRIPT="$ROOT/wire-bindings-local.sh"
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT
failures=0

fail() {
    printf 'FAIL: %s\n' "$1" >&2
    failures=$((failures + 1))
}

# A workspace with built iOS bindings; the XCFramework is passed in.
make_workspace() {
    local ws="$1"
    mkdir -p "$ws/scripts" "$ws/ios/Vauchi/Generated" "$ws/ios/Vauchi/Libs" \
        "$ws/vauchi-platform-swift/Sources/VauchiPlatform"
    cp "$SCRIPT" "$ws/scripts/"
    echo "// bindings" > "$ws/ios/Vauchi/Generated/vauchi_platform.swift"
    echo "// header" > "$ws/ios/Vauchi/Generated/vauchi_platformFFI.h"
    echo "device-lib" > "$ws/ios/Vauchi/Libs/libvauchi_platform_device.a"
    echo 'let local = "VAUCHI_PLATFORM_USE_LOCAL_XCFRAMEWORK"' \
        > "$ws/vauchi-platform-swift/Package.swift"
}

dangling="$WORK/dangling"
make_workspace "$dangling"
ln -s "$WORK/deleted/VauchiPlatformFFI.xcframework" \
    "$dangling/vauchi-platform-swift/VauchiPlatformFFI.xcframework"
if out=$("$dangling/scripts/wire-bindings-local.sh" --ios 2>&1); then
    fail "a dangling XCFramework link was reported as wired: $out"
elif ! grep -q "VauchiPlatformFFI.xcframework" <<<"$out"; then
    fail "the error does not name the XCFramework: $out"
fi

present="$WORK/present"
make_workspace "$present"
fw="$present/vauchi-platform-swift/VauchiPlatformFFI.xcframework/ios-arm64/VauchiPlatformFFI.framework"
mkdir -p "$fw/Headers" "$fw/Modules"
if ! out=$("$present/scripts/wire-bindings-local.sh" --ios 2>&1); then
    fail "a present XCFramework failed to wire: $out"
elif [[ "$(cat "$fw/VauchiPlatformFFI")" != "device-lib" ]]; then
    fail "the device slice did not receive the local library"
fi

if [[ "$failures" -ne 0 ]]; then
    exit 1
fi

echo "PASS: wire-bindings-local fails when no XCFramework slice is updated"
