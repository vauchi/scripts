#!/usr/bin/env bash
# SPDX-FileCopyrightText: 2026 Mattia Egloff <mattia.egloff@pm.me>
# SPDX-License-Identifier: GPL-3.0-or-later

set -euo pipefail
script_dir=$(cd "$(dirname "$0")" && pwd)
gate=${1:-$script_dir/../architecture-check.sh}
fixture=$(mktemp -d)
trap 'rm -rf "$fixture"' EXIT
mkdir -p "$fixture/source" "$fixture/bin"
for tool in rustc git; do
    printf '#!/usr/bin/env bash\nexit 0\n' > "$fixture/bin/$tool"
    chmod +x "$fixture/bin/$tool"
done
cat > "$fixture/bin/cargo" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$@" > "$ARCHITECTURE_CAPTURE"
exit 42
SH
chmod +x "$fixture/bin/cargo"
status=0
ARCHITECTURE_CAPTURE="$fixture/arguments" CARGO_BUILD_JOBS=4 PATH="$fixture/bin:$PATH" \
    bash "$gate" "$fixture/source" scan > "$fixture/log" 2>&1 || status=$?
[[ "$status" == 2 ]] || { cat "$fixture/log" >&2; exit 1; }
if ! awk 'previous == "-j" { if ($0 == "4") found=1 } {previous=$0} END {exit !found}' "$fixture/arguments"; then
    echo 'FAIL: architecture build must pass the configured four-job limit to Cargo' >&2
    exit 1
fi
echo 'PASS: architecture build respects the host job limit'
