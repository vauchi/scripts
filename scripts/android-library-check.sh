#!/usr/bin/env bash
# SPDX-FileCopyrightText: 2026 Mattia Egloff <mattia.egloff@pm.me>
# SPDX-License-Identifier: GPL-3.0-or-later
# Run the root Android project's native unit, lint and release gates (#773).
# Usage: android-library-check.sh <repository root>
set -euo pipefail

root="${1:?usage: android-library-check.sh <repository root>}"
if [[ ! -f "$root/src/main/AndroidManifest.xml" ||
    ( ! -f "$root/build.gradle.kts" && ! -f "$root/build.gradle" ) ]]; then
    echo "FAILED: root Android project metadata is missing: $root" >&2
    exit 1
fi
if [[ ! -x "$root/gradlew" ]]; then
    echo "FAILED: gradlew is missing or not executable: $root" >&2
    exit 1
fi
if [[ -n "${VAUCHI_ANDROID_JAVA_HOME:-}" ]]; then
    if [[ ! -x "$VAUCHI_ANDROID_JAVA_HOME/bin/java" ]]; then
        echo "FAILED: Android JAVA_HOME has no executable java: $VAUCHI_ANDROID_JAVA_HOME" >&2
        exit 1
    fi
    export JAVA_HOME="$VAUCHI_ANDROID_JAVA_HOME"
    export PATH="$JAVA_HOME/bin:$PATH"
fi
cd "$root"
exec ./gradlew --no-daemon testDebugUnitTest lintDebug assembleRelease
