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
        *) echo -e "${RED}Unknown option: $1${NC}"; exit 1 ;;
    esac
done

if $WIRE_ALL; then
    WIRE_IOS=true
    WIRE_ANDROID=true
fi

# ── iOS ──────────────────────────────────────────────────────────────

wire_ios() {
    local ios_dir="$WORKSPACE_ROOT/ios"
    local spm_dir="$WORKSPACE_ROOT/vauchi-mobile-swift"
    local gen_dir="$ios_dir/Vauchi/Generated"
    local libs_dir="$ios_dir/Vauchi/Libs"

    echo -e "${BLUE}=== Wiring iOS local bindings ===${NC}"

    # Verify prerequisites
    if [[ ! -f "$gen_dir/vauchi_mobile.swift" ]]; then
        echo -e "${RED}Error: $gen_dir/vauchi_mobile.swift not found.${NC}"
        echo "Run 'just bindings' first."
        exit 1
    fi
    if [[ ! -d "$spm_dir" ]]; then
        echo -e "${RED}Error: $spm_dir not found.${NC}"
        echo "Clone vauchi-mobile-swift as a sibling repo."
        exit 1
    fi

    # 1. Copy Swift bindings to local SPM package
    echo -e "${YELLOW}Copying Swift bindings to vauchi-mobile-swift...${NC}"
    cp "$gen_dir/vauchi_mobile.swift" "$spm_dir/Sources/VauchiMobile/vauchi_mobile.swift"

    # 2. Update XCFramework with local static libs and headers
    for slice_dir in "$spm_dir"/VauchiMobileFFI.xcframework/ios-*/; do
        local fw_dir="$slice_dir/VauchiMobileFFI.framework"
        [[ -d "$fw_dir" ]] || continue

        local slice_name
        slice_name="$(basename "$slice_dir")"

        # Copy header
        cp "$gen_dir/vauchi_mobileFFI.h" "$fw_dir/Headers/vauchi_mobileFFI.h"

        # Fix modulemap: UniFFI generates lowercase module name, but the
        # framework module must match the framework name (VauchiMobileFFI)
        cat > "$fw_dir/Modules/module.modulemap" <<'MODULEMAP'
framework module VauchiMobileFFI {
    header "vauchi_mobileFFI.h"
    export *
}
MODULEMAP

        # Copy the right static library into the framework binary
        if [[ "$slice_name" == *"simulator"* ]] && [[ -f "$libs_dir/libvauchi_mobile_sim.a" ]]; then
            cp "$libs_dir/libvauchi_mobile_sim.a" "$fw_dir/VauchiMobileFFI"
            echo -e "  ${GREEN}Updated $slice_name (simulator)${NC}"
        elif [[ -f "$libs_dir/libvauchi_mobile_device.a" ]]; then
            cp "$libs_dir/libvauchi_mobile_device.a" "$fw_dir/VauchiMobileFFI"
            echo -e "  ${GREEN}Updated $slice_name (device)${NC}"
        fi
    done

    # 3. Switch Package.swift to local binaryTarget
    #    Replace the URL-based binaryTarget with a local path reference.
    #    We use Python for reliable multi-line replacement (sed is fragile here).
    if grep -q 'url:.*gitlab.*xcframework' "$spm_dir/Package.swift"; then
        echo -e "${YELLOW}Switching Package.swift to local binaryTarget...${NC}"
        python3 -c "
import re, sys
path = sys.argv[1]
with open(path) as f:
    content = f.read()
# Match the .binaryTarget block with URL
pattern = r'(        )\.binaryTarget\(\s*\n\s*name: \"VauchiMobileFFI\",\s*\n\s*url:.*\n\s*checksum:.*\n\s*\),'
replacement = r'''\1// REMOTE (original, restored by wire-bindings-remote.sh):
\1// .binaryTarget(
\1//     name: \"VauchiMobileFFI\",
\1//     url: \"...\",
\1//     checksum: checksum
\1// ),
\1// LOCAL (set by wire-bindings-local.sh):
\1.binaryTarget(
\1    name: \"VauchiMobileFFI\",
\1    path: \"VauchiMobileFFI.xcframework\"
\1),'''
result = re.sub(pattern, replacement, content)
with open(path, 'w') as f:
    f.write(result)
" "$spm_dir/Package.swift"
        echo -e "  ${GREEN}Package.swift → local path${NC}"
    else
        echo -e "  ${YELLOW}Package.swift already using local path${NC}"
    fi

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
      location = "group:../vauchi-mobile-swift">
   </FileRef>
</Workspace>
WORKSPACE
    echo -e "  ${GREEN}Created Vauchi.xcworkspace with local package${NC}"

    # 5. Drop cached SPM resolution so Xcode picks up the local package
    rm -f "$ios_dir/Vauchi.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved"

    echo -e "${GREEN}iOS wired to local bindings.${NC}"
    echo ""
    echo "Build with:"
    echo "  xcodebuild -workspace Vauchi.xcworkspace -scheme Vauchi ..."
}

# ── Android ──────────────────────────────────────────────────────────

wire_android() {
    local android_dir="$WORKSPACE_ROOT/android"
    local gradle="$android_dir/app/build.gradle.kts"

    echo -e "${BLUE}=== Wiring Android local bindings ===${NC}"

    # Verify prerequisites
    if [[ ! -d "$android_dir/app/src/main/jniLibs/arm64-v8a" ]] || \
       [[ ! -d "$android_dir/app/src/local-bindings/kotlin/uniffi" ]]; then
        echo -e "${RED}Error: local bindings not found. Run 'just bindings' first.${NC}"
        exit 1
    fi

    # Verify build.gradle.kts has the localBindings flag
    if grep -q 'useLocalBindings' "$gradle"; then
        echo -e "  ${GREEN}build.gradle.kts has localBindings support${NC}"
    else
        echo -e "${RED}Error: build.gradle.kts missing useLocalBindings flag.${NC}"
        echo "Add the conditional dependency block — see .claude/docs/local-bindings.md"
        exit 1
    fi

    echo -e "${GREEN}Android ready for local bindings.${NC}"
    echo ""
    echo "Build with:"
    echo "  cd android && ./gradlew assembleDebug -PlocalBindings"
}

# ── Main ─────────────────────────────────────────────────────────────

echo -e "${YELLOW}╔════════════════════════════════════════╗${NC}"
echo -e "${YELLOW}║    Wire Local UniFFI Bindings          ║${NC}"
echo -e "${YELLOW}╚════════════════════════════════════════╝${NC}"
echo ""

if $WIRE_IOS; then wire_ios; fi
if $WIRE_ANDROID; then wire_android; fi

echo ""
echo -e "${GREEN}Done. To revert: ./scripts/wire-bindings-remote.sh${NC}"
