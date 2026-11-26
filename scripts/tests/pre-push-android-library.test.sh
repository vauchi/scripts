#!/usr/bin/env bash
# SPDX-FileCopyrightText: 2026 Mattia Egloff <mattia.egloff@pm.me>
# SPDX-License-Identifier: GPL-3.0-or-later
# Native Android libraries must execute the same unit/lint/AAR gate as CI (#773).
set -euo pipefail

DIR="$(cd "$(dirname "$0")/../.." && pwd)"
HOOK="$DIR/hooks/pre-push"
RUNNER="$DIR/scripts/android-library-check.sh"
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
passed=0
failed=0

check() {
    if [[ "$2" == "$3" ]]; then
        passed=$((passed + 1))
    else
        failed=$((failed + 1))
        printf 'FAIL: %s; want %s, got %s\n' "$1" "$2" "$3" >&2
    fi
}

repo="$work/native library"
mkdir -p "$repo/src/main" "$work/jdk with spaces/bin"
ln -s "$DIR" "$work/scripts"
printf '<manifest/>\n' > "$repo/src/main/AndroidManifest.xml"
printf 'plugins { id("com.android.library") }\n' > "$repo/build.gradle.kts"
cat > "$repo/gradlew" <<'SH'
#!/bin/sh
printf '%s\n' "$@" > "$FAKE_GRADLE_LOG"
printf '%s\n' "$PWD" > "$FAKE_GRADLE_CWD"
printf '%s\n' "$JAVA_HOME" > "$FAKE_GRADLE_JAVA"
exit "$FAKE_GRADLE_STATUS"
SH
printf '#!/bin/sh\nexit 0\n' > "$work/jdk with spaces/bin/java"
chmod +x "$repo/gradlew" "$work/jdk with spaces/bin/java"
export FAKE_GRADLE_LOG="$work/args" FAKE_GRADLE_CWD="$work/cwd" FAKE_GRADLE_JAVA="$work/java"
export FAKE_GRADLE_STATUS=0

# Exercise the real hook's Android dispatch, with only its timing wrapper supplied.
{
    printf 'set -euo pipefail\nREPO_ROOT=$1\nREPO_DIR=$(basename "$1")\n'
    printf 'time_step() { shift; "$@"; }\nif false; then :\n'
    awk '/# ─── Android\/Kotlin repo/{copy=1;next} /# ─── Docs\/markdown repos/{exit} copy{print}' "$HOOK"
    printf 'else echo "unhandled project type" >&2; exit 9\nfi\n'
} > "$work/dispatch"

run() {
    local script="$1"
    shift
    if env "$@" bash "$script" "$repo" > "$work/out" 2>&1; then
        status=0
    else
        status=$?
    fi
}

run "$work/dispatch"
check "the real hook dispatches a root Android library" 0 "$status"

if [[ ! -f "$RUNNER" ]]; then
    printf 'FAIL: missing Android library runner\n' >&2
    exit 1
fi

run "$RUNNER"
check "the standalone runner succeeds" 0 "$status"
check "it runs from the repository with spaces" "$repo" "$(cat "$work/cwd")"
expected=$(printf '%s\n' --no-daemon testDebugUnitTest lintDebug assembleRelease)
check "it executes all CI tasks without local binding overrides" "$expected" "$(cat "$work/args")"

mv "$repo/build.gradle.kts" "$repo/build.gradle"
run "$work/dispatch"
check "Groovy root Android projects also dispatch" 0 "$status"

run "$RUNNER" FAKE_GRADLE_STATUS=23
check "a failed backend propagates its status" 23 "$status"
run "$work/dispatch" FAKE_GRADLE_STATUS=23
check "the hook fails when its Gradle gate fails" 23 "$status"

run "$RUNNER" VAUCHI_ANDROID_JAVA_HOME="$work/jdk with spaces"
check "an explicit executable Java override succeeds" 0 "$status"
check "the override reaches Gradle unchanged" "$work/jdk with spaces" "$(cat "$work/java")"
run "$RUNNER" VAUCHI_ANDROID_JAVA_HOME="$work/missing jdk"
check "an invalid explicit Java override fails" 1 "$status"
check "the invalid Java override is named" 1 "$(grep -c 'JAVA_HOME has no executable java' "$work/out")"

chmod -x "$repo/gradlew"
run "$RUNNER"
check "a nonexecutable wrapper fails" 1 "$status"
check "the missing wrapper is named" 1 "$(grep -c 'gradlew is missing or not executable' "$work/out")"
chmod +x "$repo/gradlew"
rm "$repo/src/main/AndroidManifest.xml"
run "$RUNNER"
check "missing Android project metadata fails" 1 "$status"
run "$work/dispatch"
check "an unrelated Gradle project is not accepted" 9 "$status"

code_pattern=$(sed -n "s/^[[:space:]]*CODE_PATTERN='\(.*\)'$/\1/p" "$HOOK")
build_pattern=$(sed -n "s/^[[:space:]]*BUILD_PATTERN='\(.*\)'$/\1/p" "$HOOK")
for path in build.gradle.kts settings.gradle.kts gradle.lockfile \
    gradle/wrapper/gradle-wrapper.properties gradle/wrapper/gradle-wrapper.jar \
    gradlew gradlew.bat src/main/AndroidManifest.xml src/main/res/values/strings.xml; do
    if printf '%s\n' "$path" | grep -qE "$code_pattern|$build_pattern"; then
        classified=code
    else
        classified=skipped
    fi
    check "$path triggers the checks" code "$classified"
done
for path in README.md docs/build-notes.md assets/logo.png; do
    if printf '%s\n' "$path" | grep -qE "$code_pattern|$build_pattern"; then
        classified=code
    else
        classified=skipped
    fi
    check "$path retains its non-code fast path" skipped "$classified"
done

printf '%s passed, %s failed\n' "$passed" "$failed"
[[ "$failed" == 0 ]]
