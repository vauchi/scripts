#!/usr/bin/env bash
# SPDX-FileCopyrightText: 2026 Mattia Egloff <mattia.egloff@pm.me>
#
# SPDX-License-Identifier: GPL-3.0-or-later

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BUILD_SCRIPT="$SCRIPT_DIR/../e2e/build-binaries.sh"
fixture="$(mktemp -d)"
trap 'rm -rf "$fixture"' EXIT

mkdir -p "$fixture/scripts/scripts/e2e" "$fixture/fake-bin"
mkdir -p "$fixture/cli/src" "$fixture/relay/src" "$fixture/ohttp-relay/src"
awk '!/^build_if_changed /' "$BUILD_SCRIPT" \
    > "$fixture/scripts/scripts/e2e/build-binaries.sh"
printf 'fn main() {}\n' > "$fixture/cli/src/main.rs"
printf 'fn main() {}\n' > "$fixture/relay/src/main.rs"
printf 'fn main() {}\n' > "$fixture/ohttp-relay/src/main.rs"

cat > "$fixture/fake-bin/cargo" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf '%s|%s\n' "$(basename "$PWD")" "$*" >> "$CARGO_LOG"
case "$(basename "$PWD")" in
    cli)
        output="$FIXTURE_ROOT/target/release/vauchi"
        ;;
    relay)
        output="$FIXTURE_ROOT/target/release/vauchi-relay"
        mkdir -p "$(dirname "$output")"
        : > "$FIXTURE_ROOT/target/release/vauchi-ohttp-anchor"
        ;;
    ohttp-relay)
        output="$PWD/target/release/vauchi-ohttp-relay"
        ;;
    *)
        exit 2
        ;;
esac
mkdir -p "$(dirname "$output")"
: > "$output"
EOF
chmod +x "$fixture/fake-bin/cargo"

CARGO_LOG="$fixture/cargo.log" FIXTURE_ROOT="$fixture" \
    PATH="$fixture/fake-bin:$PATH" \
    bash "$fixture/scripts/scripts/e2e/build-binaries.sh" >/dev/null

failures=0

if grep -q '^ohttp-relay|build --release --features e2e-faults ' "$fixture/cargo.log"; then
    echo "PASS: E2E OHTTP relay enables fault-controller endpoints"
else
    echo "FAIL: E2E OHTTP relay build omitted --features e2e-faults" >&2
    failures=$((failures + 1))
fi

# #288: e2e moves the relay across OHTTP windows with its test clock.
if grep -q '^relay|build --release .*--features e2e-test-clock' "$fixture/cargo.log"; then
    echo "PASS: E2E relay enables the OHTTP test clock"
else
    echo "FAIL: E2E relay build omitted --features e2e-test-clock" >&2
    failures=$((failures + 1))
fi

# #288: e2e provisions each relay's test anchor with the ceremony CLI.
if [ -f "$fixture/target/e2e-bin/vauchi-ohttp-anchor" ]; then
    echo "PASS: E2E bin dir carries vauchi-ohttp-anchor next to the relay"
else
    echo "FAIL: vauchi-ohttp-anchor missing from the E2E bin dir" >&2
    failures=$((failures + 1))
fi

if [ "$failures" -ne 0 ]; then
    cat "$fixture/cargo.log" >&2
    exit 1
fi
