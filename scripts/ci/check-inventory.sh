#!/usr/bin/env bash
# SPDX-FileCopyrightText: 2026 Mattia Egloff <mattia.egloff@pm.me>
# SPDX-License-Identifier: GPL-3.0-or-later

# check-inventory.sh — Verify INVENTORY.md component table matches filesystem.
#
# Fails CI if:
#   - A file listed in INVENTORY.md does not exist on disk (stale doc)
#   - A component file exists on disk but is not listed in INVENTORY.md (undocumented)
#
# Usage:
#   check-inventory.sh <inventory_md> <component_dir> <file_ext>
#
# Examples:
#   check-inventory.sh design/INVENTORY.md src/core_ui/components .rs
#   check-inventory.sh design/INVENTORY.md src/coreui/components .cpp

set -euo pipefail

INVENTORY="${1:?Usage: check-inventory.sh <inventory_md> <component_dir> <file_ext>}"
COMP_DIR="${2:?Missing component directory}"
FILE_EXT="${3:?Missing file extension}"

if [ ! -f "$INVENTORY" ]; then
    echo "ERROR: $INVENTORY not found"
    exit 1
fi
if [ ! -d "$COMP_DIR" ]; then
    echo "ERROR: $COMP_DIR not found"
    exit 1
fi

# Extract filenames from INVENTORY.md table rows.
# Matches backtick-wrapped filenames like `text.rs` or `textcomponent.cpp`.
# Skips the mod.rs / mod.cpp dispatcher and icons module.
inventory_files=$(grep -E '^\| *[0-9]' "$INVENTORY" \
    | grep -oE '`[^`]+'"${FILE_EXT}"'`' \
    | tr -d '`' \
    | sort -u)

# List actual component files on disk (exclude mod files and non-component dirs).
disk_files=$(find "$COMP_DIR" -maxdepth 1 -name "*${FILE_EXT}" -not -name "mod${FILE_EXT}" \
    | sed "s|.*/||" \
    | sort -u)

errors=0

# Check 1: Every file in INVENTORY must exist on disk
while IFS= read -r f; do
    [ -z "$f" ] && continue
    if ! echo "$disk_files" | grep -qxF "$f"; then
        echo "STALE DOC: $INVENTORY lists '$f' but $COMP_DIR/$f does not exist"
        errors=$((errors + 1))
    fi
done <<< "$inventory_files"

# Check 2: Every file on disk must appear in INVENTORY
while IFS= read -r f; do
    [ -z "$f" ] && continue
    # Skip known non-component files (icons dir, helpers, etc.)
    case "$f" in icons.*) continue ;; esac
    if ! echo "$inventory_files" | grep -qxF "$f"; then
        echo "UNDOCUMENTED: $COMP_DIR/$f exists but is not listed in $INVENTORY"
        errors=$((errors + 1))
    fi
done <<< "$disk_files"

# Summary
inv_count=$(echo "$inventory_files" | grep -c . || true)
# Count only non-excluded disk files
disk_counted=0
while IFS= read -r f; do
    [ -z "$f" ] && continue
    case "$f" in icons.*) continue ;; esac
    disk_counted=$((disk_counted + 1))
done <<< "$disk_files"

if [ "$errors" -eq 0 ]; then
    echo "OK: INVENTORY ($inv_count entries) matches filesystem ($disk_counted files)"
    exit 0
else
    echo ""
    echo "FAILED: $errors mismatches between $INVENTORY and $COMP_DIR/"
    echo "  INVENTORY entries: $inv_count"
    echo "  Filesystem files:  $disk_counted"
    exit 1
fi
