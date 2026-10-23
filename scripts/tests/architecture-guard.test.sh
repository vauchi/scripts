#!/usr/bin/env bash
# SPDX-FileCopyrightText: 2026 Mattia Egloff <mattia.egloff@pm.me>
# SPDX-License-Identifier: GPL-3.0-or-later
set -euo pipefail
scripts_root=$(cd "$(dirname "$0")/../.." && pwd)
guard="$scripts_root/hooks/lib/architecture-guard.sh"
fixture=$(mktemp -d)
trap 'rm -rf "$fixture"' EXIT
mkdir -p "$fixture/core/vauchi-core" "$fixture/scripts/scripts" "$fixture/other"
touch "$fixture/core/vauchi-core/Cargo.toml"
bash "$guard" "$fixture/other"
status=0
bash "$guard" "$fixture/core" > "$fixture/log" 2>&1 || status=$?
[[ "$status" == 1 ]] || { echo 'Missing gate was not blocked'; exit 1; }
grep -q VRS06 "$fixture/log"
printf '#!/usr/bin/env bash\nexit 23\n' > "$fixture/scripts/scripts/architecture-check.sh"
status=0
bash "$guard" "$fixture/core" > "$fixture/log" 2>&1 || status=$?
[[ "$status" == 23 ]] || { echo 'Gate failure was swallowed'; exit 1; }
printf '#!/usr/bin/env bash\nexit 0\n' > "$fixture/scripts/scripts/architecture-check.sh"
bash "$guard" "$fixture/core"
echo 'Architecture push guard: missing script and failing gate block; passing gate proceeds.'
