#!/usr/bin/env bash
# SPDX-FileCopyrightText: 2026 Mattia Egloff <mattia.egloff@pm.me>
# SPDX-License-Identifier: GPL-3.0-or-later
#
# The pre-push check runner for a .NET repository (windows-hw, windows):
# `dotnet test` on every test project under tests/ and on a *.UnitTests
# project at the root, then the repository's own Python checks in
# ci/tests. A project that targets Windows builds on a Windows host only;
# elsewhere it is named and left to CI. Nothing is restored or installed
# here beyond what `dotnet test` does for the project it runs.
#
# Usage: dotnet-check.sh <repository root>
set -uo pipefail

root="${1:?usage: dotnet-check.sh <repository root>}"

command -v dotnet >/dev/null 2>&1 || {
    echo "FAILED: dotnet is not installed; install the .NET SDK this repository's CI uses." >&2
    exit 1
}

host=$(uname -s)
case "$host" in
    MINGW* | MSYS* | CYGWIN*) on_windows=1 ;;
    *) on_windows=0 ;;
esac

ran=0
skipped=0
for project in "$root"/tests/*/*.csproj "$root"/*.UnitTests/*.UnitTests.csproj; do
    [ -f "$project" ] || continue
    name=${project#"$root"/}
    if [ "$on_windows" = 0 ] && grep -qE '<TargetFrameworks?>[^<]*-windows' "$project"; then
        echo "  SKIP $name: it targets Windows and this host is $host; its pipeline runs it"
        skipped=$((skipped + 1))
        continue
    fi
    echo "  dotnet test $name"
    dotnet test "$project" --nologo || {
        echo "FAILED: dotnet test $name" >&2
        exit 1
    }
    ran=$((ran + 1))
done

for check in "$root"/ci/tests/*.test.py; do
    [ -f "$check" ] || continue
    name=${check#"$root"/}
    echo "  python3 $name"
    python3 "$check" || {
        echo "FAILED: $name" >&2
        exit 1
    }
    ran=$((ran + 1))
done

if [ "$ran" = 0 ] && [ "$skipped" = 0 ]; then
    echo "FAILED: no test project under tests/ or *.UnitTests/, and no ci/tests/*.test.py: nothing was checked." >&2
    exit 1
fi
echo "  .NET checks: $ran run, $skipped left to the pipeline"
