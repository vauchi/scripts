#!/usr/bin/env bash
# SPDX-FileCopyrightText: 2026 Mattia Egloff <mattia.egloff@pm.me>
#
# SPDX-License-Identifier: GPL-3.0-or-later
#
# Wire local UniFFI bindings into iOS and Android build systems.
#
# After `just bindings` builds and copies artifacts, this script configures
# the platform projects to USE those local artifacts instead of the published
# remote packages.
#
# Usage: ./scripts/wire-bindings-local.sh [--ios] [--android]
#        (no args = both platforms)
#
# Reverse with: ./scripts/wire-bindings-remote.sh

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
            echo "Wire local UniFFI bindings into platform build systems."
            echo "Run 'just bindings' first to generate and copy artifacts."
            echo "Reverse with: wire-bindings-remote.sh"
            exit 0
            ;;
        *) printf '%b\n' "${RED}Unknown option: $1${NC}"; exit 1 ;;
    esac
done

if $WIRE_ALL; then
    WIRE_IOS=true
    WIRE_ANDROID=true
fi

# ── iOS ──────────────────────────────────────────────────────────────

wire_ios() {
    local ios_dir="$WORKSPACE_ROOT/ios"
    local spm_dir="$WORKSPACE_ROOT/vauchi-platform-swift"
    local gen_dir="$ios_dir/Vauchi/Generated"
    local libs_dir="$ios_dir/Vauchi/Libs"

    printf '%b\n' "${BLUE}=== Wiring iOS local bindings ===${NC}"

    # Verify prerequisites
    if [[ ! -f "$gen_dir/vauchi_platform.swift" ]]; then
        printf '%b\n' "${RED}Error: $gen_dir/vauchi_platform.swift not found.${NC}"
        echo "Run 'just bindings' first."
        exit 1
    fi
    if [[ ! -d "$spm_dir" ]]; then
        printf '%b\n' "${RED}Error: $spm_dir not found.${NC}"
        echo "Clone vauchi-platform-swift as a sibling repo."
        exit 1
    fi

    # 1. Copy Swift bindings to local SPM package
    printf '%b\n' "${YELLOW}Copying Swift bindings to vauchi-platform-swift...${NC}"
    cp "$gen_dir/vauchi_platform.swift" "$spm_dir/Sources/VauchiPlatform/vauchi_platform.swift"

    # 2. Update XCFramework with local static libs and headers
    for slice_dir in "$spm_dir"/VauchiPlatformFFI.xcframework/ios-*/; do
        local fw_dir="$slice_dir/VauchiPlatformFFI.framework"
        [[ -d "$fw_dir" ]] || continue

        local slice_name
        slice_name="$(basename "$slice_dir")"

        # Copy header
        cp "$gen_dir/vauchi_platformFFI.h" "$fw_dir/Headers/vauchi_platformFFI.h"

        # Fix modulemap: UniFFI generates lowercase module name, but the
        # framework module must match the framework name (VauchiPlatformFFI)
        cat > "$fw_dir/Modules/module.modulemap" <<'MODULEMAP'
framework module VauchiPlatformFFI {
    header "vauchi_platformFFI.h"
    export *
}
MODULEMAP

        # Copy the right static library into the framework binary
        if [[ "$slice_name" == *"simulator"* ]] && [[ -f "$libs_dir/libvauchi_platform_sim.a" ]]; then
            cp "$libs_dir/libvauchi_platform_sim.a" "$fw_dir/VauchiPlatformFFI"
            printf '%b\n' "  ${GREEN}Updated $slice_name (simulator)${NC}"
        elif [[ -f "$libs_dir/libvauchi_platform_device.a" ]]; then
            cp "$libs_dir/libvauchi_platform_device.a" "$fw_dir/VauchiPlatformFFI"
            printf '%b\n' "  ${GREEN}Updated $slice_name (device)${NC}"
        fi
    done

    # 3. Verify Package.swift carries the env-var-aware binaryTarget.
    #    Since 2026-04-26 (problem 2026-04-26-vauchi-platform-swift-resolve-hang),
    #    no Package.swift mutation is needed: the manifest reads
    #    VAUCHI_PLATFORM_USE_LOCAL_XCFRAMEWORK at SPM resolve time and emits
    #    a `path:` binaryTarget when the env var is set. This avoids the
    #    SwiftPM URLSession download path entirely without touching the file.
    if ! grep -q 'VAUCHI_PLATFORM_USE_LOCAL_XCFRAMEWORK' "$spm_dir/Package.swift"; then
        printf '%b\n' "${RED}Error: $spm_dir/Package.swift is missing the env-var-aware binaryTarget.${NC}"
        echo "Pull the latest vauchi-platform-swift main (must contain Fix C — see"
        echo "_private/docs/problems/2026-04-26-vauchi-platform-swift-resolve-hang/)."
        exit 1
    fi
    printf '%b\n' "  ${GREEN}Package.swift uses env-var-aware binaryTarget (no patch needed)${NC}"

    # 4. Create Xcode workspace that includes the local SPM package
    local ws_dir="$ios_dir/Vauchi.xcworkspace"
    mkdir -p "$ws_dir"
    cat > "$ws_dir/contents.xcworkspacedata" <<'WORKSPACE'
<?xml version="1.0" encoding="UTF-8"?>
<Workspace
   version = "1.0">
   <FileRef
      location = "container:Vauchi.xcodeproj">
   </FileRef>
   <FileRef
      location = "group:../vauchi-platform-swift">
   </FileRef>
</Workspace>
WORKSPACE
    printf '%b\n' "  ${GREEN}Created Vauchi.xcworkspace with local package${NC}"

    # 5. Drop cached SPM resolution so Xcode picks up the local package
    rm -f "$ios_dir/Vauchi.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved"

    printf '%b\n' "${GREEN}iOS wired to local bindings.${NC}"
    echo ""
    echo "Build with:"
    printf '%b\n' "  ${YELLOW}export VAUCHI_PLATFORM_USE_LOCAL_XCFRAMEWORK=1${NC}"
    echo "  xcodebuild -workspace Vauchi.xcworkspace -scheme Vauchi ..."
    echo ""
    echo "For Xcode IDE builds: add VAUCHI_PLATFORM_USE_LOCAL_XCFRAMEWORK=1 to"
    echo "the scheme's Run > Arguments > Environment Variables."
}

# ── Android ──────────────────────────────────────────────────────────

wire_android() {
    local android_dir="$WORKSPACE_ROOT/android"
    local gradle="$android_dir/app/build.gradle.kts"

    printf '%b\n' "${BLUE}=== Wiring Android local bindings ===${NC}"

    # Verify prerequisites
    if [[ ! -d "$android_dir/app/src/main/jniLibs/arm64-v8a" ]] || \
       [[ ! -d "$android_dir/app/src/local-bindings/kotlin/uniffi" ]]; then
        printf '%b\n' "${RED}Error: local bindings not found. Run 'just bindings' first.${NC}"
        exit 1
    fi

    # Verify build.gradle.kts has the localBindings flag
    if grep -q 'useLocalBindings' "$gradle"; then
        printf '%b\n' "  ${GREEN}build.gradle.kts has localBindings support${NC}"
    else
        printf '%b\n' "${RED}Error: build.gradle.kts missing useLocalBindings flag.${NC}"
        echo "Add the conditional dependency block — see .claude/docs/local-bindings.md"
        exit 1
    fi

    printf '%b\n' "${GREEN}Android ready for local bindings.${NC}"
    echo ""
    echo "Build with:"
    echo "  cd android && ./gradlew assembleDebug -PlocalBindings"
}

# ── Main ─────────────────────────────────────────────────────────────

printf '%b\n' "${YELLOW}╔════════════════════════════════════════╗${NC}"
printf '%b\n' "${YELLOW}║    Wire Local UniFFI Bindings          ║${NC}"
printf '%b\n' "${YELLOW}╚════════════════════════════════════════╝${NC}"
echo ""

if $WIRE_IOS; then wire_ios; fi
if $WIRE_ANDROID; then wire_android; fi

echo ""
printf '%b\n' "${GREEN}Done. To revert: ./scripts/wire-bindings-remote.sh${NC}"
