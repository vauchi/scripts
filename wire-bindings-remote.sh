#!/usr/bin/env bash
# SPDX-FileCopyrightText: 2026 Mattia Egloff <mattia.egloff@pm.me>
#
# SPDX-License-Identifier: GPL-3.0-or-later
#
# Revert local UniFFI bindings wiring — restore remote/published dependencies.
#
# Undoes changes made by wire-bindings-local.sh:
#   iOS:     removes workspace, restores Package.swift to URL target
#   Android: reverts build.gradle.kts to Maven dependency
#
# Usage: ./scripts/wire-bindings-remote.sh [--ios] [--android]
#        (no args = both platforms)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WORKSPACE_ROOT="$(dirname "$SCRIPT_DIR")"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

WIRE_IOS=false
WIRE_ANDROID=false
WIRE_ALL=true

while [[ $# -gt 0 ]]; do
    case $1 in
        --ios) WIRE_IOS=true; WIRE_ALL=false; shift ;;
        --android) WIRE_ANDROID=true; WIRE_ALL=false; shift ;;
        --help|-h)
            echo "Usage: $0 [--ios] [--android]"
            echo ""
            echo "Revert to published (remote) UniFFI bindings."
            exit 0
            ;;
        *) echo -e "${RED}Unknown option: $1${NC}"; exit 1 ;;
    esac
done

if $WIRE_ALL; then
    WIRE_IOS=true
    WIRE_ANDROID=true
fi

# ── iOS ──────────────────────────────────────────────────────────────

unwire_ios() {
    local ios_dir="$WORKSPACE_ROOT/ios"
    local spm_dir="$WORKSPACE_ROOT/vauchi-platform-swift"

    echo -e "${BLUE}=== Restoring iOS remote bindings ===${NC}"

    # 1. Remove the workspace (project builds use .xcodeproj directly)
    if [[ -d "$ios_dir/Vauchi.xcworkspace" ]]; then
        rm -rf "$ios_dir/Vauchi.xcworkspace"
        echo -e "  ${GREEN}Removed Vauchi.xcworkspace${NC}"
    fi

    # 2. Restore Package.swift to remote binaryTarget
    if [[ -d "$spm_dir" ]] && grep -q 'path: "VauchiPlatformFFI.xcframework"' "$spm_dir/Package.swift" 2>/dev/null; then
        echo -e "${YELLOW}Restoring Package.swift to remote binaryTarget...${NC}"
        cd "$spm_dir" && git checkout -- Package.swift
        echo -e "  ${GREEN}Package.swift restored from git${NC}"
    else
        echo -e "  ${YELLOW}Package.swift already using remote target${NC}"
    fi

    # 3. Restore Swift bindings from git
    if [[ -d "$spm_dir" ]]; then
        cd "$spm_dir" && git checkout -- Sources/VauchiPlatform/vauchi_platform.swift 2>/dev/null || true
        echo -e "  ${GREEN}Swift bindings restored from git${NC}"
    fi

    echo -e "${GREEN}iOS restored to remote bindings.${NC}"
    echo ""
    echo "Build with:"
    echo "  xcodebuild -project Vauchi.xcodeproj -scheme Vauchi ..."
}

# ── Android ──────────────────────────────────────────────────────────

unwire_android() {
    local android_dir="$WORKSPACE_ROOT/android"
    local gradle="$android_dir/app/build.gradle.kts"

    echo -e "${BLUE}=== Restoring Android remote bindings ===${NC}"

    # Just build normally without -PlocalBindings flag.
    # The conditional in build.gradle.kts handles both modes — no revert needed.
    echo -e "  ${GREEN}No changes needed — build without -PlocalBindings flag${NC}"
    echo ""
    echo "Build with:"
    echo "  cd android && ./gradlew assembleDebug"

    # Optionally clean local jniLibs and kotlin (they're gitignored)
    echo ""
    echo -e "${YELLOW}Optional: remove local binding artifacts:${NC}"
    echo "  rm -rf android/app/src/main/jniLibs/"
    echo "  rm -rf android/app/src/main/kotlin/uniffi/"
}

# ── Main ─────────────────────────────────────────────────────────────

echo -e "${YELLOW}╔════════════════════════════════════════╗${NC}"
echo -e "${YELLOW}║   Restore Remote UniFFI Bindings       ║${NC}"
echo -e "${YELLOW}╚════════════════════════════════════════╝${NC}"
echo ""

if $WIRE_IOS; then unwire_ios; fi
if $WIRE_ANDROID; then unwire_android; fi

echo ""
echo -e "${GREEN}Done. Projects now use published bindings.${NC}"
