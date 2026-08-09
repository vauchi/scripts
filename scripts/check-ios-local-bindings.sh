#!/bin/sh
# SPDX-FileCopyrightText: 2026 Mattia Egloff <mattia.egloff@pm.me>
#
# SPDX-License-Identifier: GPL-3.0-or-later
#
# Did that iOS build actually use the local bindings?
#
# `wire-bindings-local.sh` tells you to export
# VAUCHI_PLATFORM_USE_LOCAL_XCFRAMEWORK before building, because
# Package.swift only emits a `path:` binaryTarget when it is set. Forget
# it and nothing goes wrong: SwiftPM quietly resolves the *published*
# XCFramework and the build succeeds, so you test a core you did not
# build. On 2026-08-09 that produced a wrong conclusion in
# `problems/2026-08-07-ios-stale-overlay-and-raw-error-alert` — the app
# under test predated the fix by three days, and the run was read as
# evidence the fix did not work.
#
# The tell is mechanical: a `path:` target needs no download, so a
# genuinely local build leaves SourcePackages/artifacts empty. A
# downloaded XCFramework sitting there means the build was not local,
# whatever the caller intended.
#
# Usage:
#   check-ios-local-bindings.sh [derived_data_dir]     (default: ios/build)
#
# Exit: 0 local (or nothing resolved yet); 1 resolved published
#       artifacts; 2 usage error.
#
# Portability: POSIX shell.
set -eu

DERIVED="${1:-ios/build}"

if [ ! -d "$DERIVED" ]; then
    printf 'check-ios-local-bindings: no derived data at %s\n' "$DERIVED" >&2
    printf 'Pass the -derivedDataPath you built with.\n' >&2
    exit 2
fi

ARTIFACTS="$DERIVED/SourcePackages/artifacts"

if [ ! -d "$ARTIFACTS" ]; then
    printf 'OK: no resolved SPM artifacts under %s\n' "$DERIVED"
    exit 0
fi

# Only the platform framework matters: it is the one with both a `path:`
# and a `url:` form. Other packages legitimately download.
downloaded=$(find "$ARTIFACTS" -name 'VauchiPlatformFFI.xcframework' 2>/dev/null | head -1)

if [ -n "$downloaded" ]; then
    printf 'FAIL: this build resolved the PUBLISHED VauchiPlatformFFI.\n' >&2
    printf '  %s\n' "$downloaded" >&2
    printf '\nIt does not contain your local core. Rebuild with:\n' >&2
    printf '  export VAUCHI_PLATFORM_USE_LOCAL_XCFRAMEWORK=1\n' >&2
    printf '\nA local build leaves SourcePackages/artifacts free of it,\n' >&2
    printf 'because a path: target needs no download.\n' >&2
    exit 1
fi

printf 'OK: no published VauchiPlatformFFI resolved — the build used the local path target\n'
