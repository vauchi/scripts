#!/usr/bin/env bash
# SPDX-FileCopyrightText: 2026 Mattia Egloff <mattia.egloff@pm.me>
#
# SPDX-License-Identifier: GPL-3.0-or-later

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DEVICE_GATE="$SCRIPT_DIR/../device-gate.sh"
fixture="$(mktemp -d)"
trap 'rm -rf "$fixture"' EXIT

mkdir -p "$fixture/scripts/scripts" "$fixture/just" \
    "$fixture/e2e/maestro/ios" "$fixture/e2e/maestro/android" \
    "$fixture/fake-bin"
cp "$DEVICE_GATE" "$fixture/scripts/scripts/device-gate.sh"
printf 'appId: app.vauchi.ios\n---\n- launchApp\n' \
    > "$fixture/e2e/maestro/ios/create_identity.yaml"
printf 'appId: app.vauchi\n---\n- launchApp\n' \
    > "$fixture/e2e/maestro/android/create_identity.yaml"

cat > "$fixture/just/device-test-lib.sh" <<'EOF'
RED=""
YELLOW=""
GREEN=""
NC=""
dt_detect_ios_device() { printf 'iphone-udid\n'; }
dt_detect_android_device() { printf '%s\n' "${ANDROID_SERIAL:-pixel-serial}"; }
EOF

cat > "$fixture/fake-bin/timeout" <<'EOF'
#!/usr/bin/env bash
shift
exec "$@"
EOF

cat > "$fixture/fake-bin/maestro" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$@" > "$MAESTRO_ARGS_FILE"
EOF

cat > "$fixture/fake-bin/adb" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF

cat > "$fixture/fake-bin/just" <<'EOF'
#!/usr/bin/env bash
if [[ "${1:-}" == "dt-screenshot-ios" && -n "${2:-}" ]]; then
    : > "$2"
fi
EOF
chmod +x "$fixture/fake-bin/timeout" "$fixture/fake-bin/maestro" \
    "$fixture/fake-bin/adb" "$fixture/fake-bin/just"

MAESTRO_ARGS_FILE="$fixture/maestro-args.txt" \
    PATH="$fixture/fake-bin:$PATH" \
    bash "$fixture/scripts/scripts/device-gate.sh" \
    ios --skip-build --flows create_identity >/dev/null

args=()
while IFS= read -r arg; do
    args[${#args[@]}]="$arg"
done < "$fixture/maestro-args.txt"
expected=(--device iphone-udid test --apple-team-id L2853TNSJ4)
for i in "${!expected[@]}"; do
    if [[ "${args[$i]:-}" != "${expected[$i]}" ]]; then
        printf 'FAIL: arg %s expected %q, got %q\n' \
            "$i" "${expected[$i]}" "${args[$i]:-<missing>}" >&2
        exit 1
    fi
done

printf 'PASS: physical iOS gate passes the global device selector before test\n'

MAESTRO_ARGS_FILE="$fixture/maestro-args.txt" \
    ANDROID_SERIAL="pixel-serial" \
    PATH="$fixture/fake-bin:$PATH" \
    bash "$fixture/scripts/scripts/device-gate.sh" \
    android --skip-build --flows create_identity >/dev/null

args=()
while IFS= read -r arg; do
    args[${#args[@]}]="$arg"
done < "$fixture/maestro-args.txt"
expected=(--device pixel-serial test)
for i in "${!expected[@]}"; do
    if [[ "${args[$i]:-}" != "${expected[$i]}" ]]; then
        printf 'FAIL: Android arg %s expected %q, got %q\n' \
            "$i" "${expected[$i]}" "${args[$i]:-<missing>}" >&2
        exit 1
    fi
done

printf 'PASS: physical Android gate accepts an empty platform option list\n'
