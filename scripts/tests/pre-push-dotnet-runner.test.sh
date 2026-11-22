#!/usr/bin/env bash
# SPDX-FileCopyrightText: 2026 Mattia Egloff <mattia.egloff@pm.me>
# SPDX-License-Identifier: GPL-3.0-or-later
# The pre-push hook had no runner for a .NET repository and did not count
# C# as code: windows pushed past every gate, and windows-hw could not be
# pushed at all once it held a Python file (vauchi/private#772, #1234).
# This pins the runner's contract with a stand-in for dotnet on PATH:
#
# - it runs `dotnet test` on every test project under tests/ and on a
#   *.UnitTests project at the root, and the repository's own Python
#   checks in ci/tests;
# - a project that targets Windows is not run on another host, and says
#   so: only a Windows host can build it;
# - a repository with nothing to run fails, a failing test fails, a
#   missing dotnet fails by name;
# - it restores and installs nothing of its own.
set -uo pipefail
DIR="$(cd "$(dirname "$0")/../.." && pwd)"
HOOK="${HOOK:-$DIR/hooks/pre-push}"
RUNNER="$DIR/scripts/dotnet-check.sh"
PASS=0
FAIL=0

check() {
    local name="$1" want="$2" got="$3"
    if [ "$want" = "$got" ]; then
        PASS=$((PASS + 1))
    else
        FAIL=$((FAIL + 1))
        printf 'FAIL: %s\n  want: %s\n  got:  %s\n' "$name" "$want" "$got" >&2
    fi
}

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

# A dotnet that records what it was asked and exits as DOTNET_EXIT says; a
# uname that answers as HOST says. Both ahead of the real ones on PATH.
mkdir -p "$work/bin"
cat > "$work/bin/dotnet" <<'SH'
#!/bin/sh
printf '%s\n' "$*" >> "$DOTNET_LOG"
exit "${DOTNET_EXIT:-0}"
SH
cat > "$work/bin/uname" <<'SH'
#!/bin/sh
printf '%s\n' "${HOST:-Linux}"
SH
chmod +x "$work/bin/dotnet" "$work/bin/uname"

project() {
    mkdir -p "$(dirname "$1")"
    printf '<Project Sdk="Microsoft.NET.Sdk"><PropertyGroup><TargetFramework>%s</TargetFramework></PropertyGroup></Project>\n' "$2" > "$1"
}

# run <repository> [VAR=value ...]: the runner's exit status; its output in
# $work/out and dotnet's arguments in $work/log.
run() {
    local repo="$1"
    shift
    : > "$work/log"
    env PATH="$work/bin:$PATH" DOTNET_LOG="$work/log" "$@" bash "$RUNNER" "$repo" > "$work/out" 2>&1
    echo $?
}

if [ ! -f "$RUNNER" ]; then
    echo "FAIL: $RUNNER does not exist" >&2
    echo "0 passed, 1 failed"
    exit 1
fi

library="$work/library"
project "$library/src/Hw/Hw.csproj" net8.0
project "$library/tests/Hw.Tests/Hw.Tests.csproj" net8.0
project "$library/tests/Hw.Native.Tests/Hw.Native.Tests.csproj" net8.0-windows10.0.19041.0
mkdir -p "$library/ci/tests"
printf 'import sys\nsys.exit(0)\n' > "$library/ci/tests/check.test.py"

check "a library's tests pass on Linux" "0" "$(run "$library")"
check "the portable test project is run, the library project is not" \
    "test $library/tests/Hw.Tests/Hw.Tests.csproj --nologo" "$(cat "$work/log")"
check "the Windows-only project is named as not run" "1" \
    "$(grep -c 'tests/Hw.Native.Tests/Hw.Native.Tests.csproj.*targets Windows' "$work/out")"

check "on a Windows host both test projects pass" "0" "$(run "$library" HOST=MINGW64_NT-10.0-26300)"
check "on a Windows host both test projects are run" "2" "$(grep -c '^test ' "$work/log")"

check "a failing dotnet test fails the push" "1" "$(run "$library" DOTNET_EXIT=1)"
check "the failure names the project" "1" "$(grep -c 'FAILED: dotnet test tests/Hw.Tests/Hw.Tests.csproj' "$work/out")"

printf 'import sys\nsys.exit(3)\n' > "$library/ci/tests/check.test.py"
check "a failing Python check fails the push" "1" "$(run "$library")"
check "the failure names the check" "1" "$(grep -c 'FAILED: ci/tests/check.test.py' "$work/out")"
printf 'import sys\nsys.exit(0)\n' > "$library/ci/tests/check.test.py"

app="$work/app"
project "$app/Vauchi/Vauchi.csproj" net8.0-windows10.0.22621.0
project "$app/Vauchi.UnitTests/Vauchi.UnitTests.csproj" net8.0-windows10.0.22621.0
project "$app/Vauchi.Tests/Vauchi.Tests.csproj" net8.0-windows10.0.22621.0
check "the app's unit tests run on a Windows host" "0" "$(run "$app" HOST=MINGW64_NT-10.0-26300)"
check "only the unit-test project is run, not the app or its launch tests" \
    "test $app/Vauchi.UnitTests/Vauchi.UnitTests.csproj --nologo" "$(cat "$work/log")"
check "on Linux the app's push passes with its project named as not run" "0" "$(run "$app")"
check "on Linux nothing is run for the app" "0" "$(grep -c '' "$work/log")"
check "on Linux the app's skipped project is named" "1" \
    "$(grep -c 'Vauchi.UnitTests/Vauchi.UnitTests.csproj.*targets Windows' "$work/out")"

empty="$work/empty"
project "$empty/src/Hw/Hw.csproj" net8.0
check "a repository with no test project fails" "1" "$(run "$empty")"
check "it says there is nothing to run" "1" "$(grep -c 'FAILED: no test project' "$work/out")"

# PATH with every directory that holds a dotnet left out, the stand-in's too.
without_dotnet=$(printf '%s' "$PATH" | tr ':' '\n' | while IFS= read -r entry; do
    if [ ! -x "$entry/dotnet" ] && [ ! -x "$entry/dotnet.exe" ]; then printf '%s:' "$entry"; fi
done)
: > "$work/log"
status=$(env PATH="$without_dotnet" DOTNET_LOG="$work/log" bash "$RUNNER" "$library" > "$work/out" 2>&1; echo $?)
check "a host without dotnet fails" "1" "$status"
check "it names dotnet" "1" "$(grep -c 'FAILED: dotnet is not installed' "$work/out")"

check "the runner restores and installs nothing of its own" "0" \
    "$(grep -vE '^\s*#' "$RUNNER" | grep -cE 'dotnet (restore|tool|workload|nuget)|pip install|apt|winget')"

# The hook reaches the runner, and C# counts as code.
net_line=$(grep -n 'dotnet-check.sh' "$HOOK" | head -1 | cut -d: -f1)
else_line=$(grep -n 'no check runner for this project type' "$HOOK" | head -1 | cut -d: -f1)
check "the hook has a .NET branch" "1" "$([ -n "$net_line" ] && echo 1 || echo 0)"
if [ -n "$net_line" ] && [ -n "$else_line" ]; then
    check "the .NET branch comes before the fail-closed branch" "1" "$([ "$net_line" -lt "$else_line" ] && echo 1 || echo 0)"
fi
CODE_PATTERN=$(sed -n "s/^[[:space:]]*CODE_PATTERN='\(.*\)'$/\1/p" "$HOOK")
BUILD_PATTERN=$(sed -n "s/^[[:space:]]*BUILD_PATTERN='\(.*\)'$/\1/p" "$HOOK")
classified() {
    if printf '%s\n' "$1" | grep -qE "$CODE_PATTERN" || printf '%s\n' "$1" | grep -qE "$BUILD_PATTERN"; then
        echo code
    else
        echo skipped
    fi
}
for path in src/Vauchi.WindowsHw/HardwareShell.cs Vauchi/MainWindow.xaml.cs Vauchi/MainWindow.xaml \
    src/Vauchi.WindowsHw/Vauchi.WindowsHw.csproj Directory.Build.props nuget.config \
    tests/Vauchi.WindowsHw.Tests/packages.lock.json; do
    check "$path counts as code" "code" "$(classified "$path")"
done
for path in README.md docs/csharp.md assets/logo.png; do
    check "$path stays on the fast path" "skipped" "$(classified "$path")"
done

echo "$PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
