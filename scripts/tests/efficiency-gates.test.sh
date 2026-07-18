#!/usr/bin/env bash
# SPDX-FileCopyrightText: 2026 Mattia Egloff <mattia.egloff@pm.me>
# SPDX-License-Identifier: GPL-3.0-or-later
set -euo pipefail
DIR="$(cd "$(dirname "$0")/.." && pwd)"
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT
mkdir -p "$WORK/.codex"
printf 'short guidance\n' > "$WORK/AGENTS.md"
printf 'other guidance\n' > "$WORK/CLAUDE.md"
printf 'hooks = true\n' > "$WORK/.codex/config.toml"
printf '# path\tbaseline\tceiling\nAGENTS.md\t16\t16\nCLAUDE.md\t15\t20\n.codex/config.toml\t14\t20\n' > "$WORK/budget.tsv"
"$DIR/check-context-budget.sh" "$WORK" "$WORK/budget.tsv" >/dev/null
python3 "$DIR/check-instruction-overlap.py" "$WORK"
printf '{"baseline":{"cost_per_outcome":100,"retry_rate":10},"current":{"cost_per_outcome":120,"retry_rate":11}}\n' > "$WORK/metrics.json"
python3 "$DIR/check-token-regression.py" "$WORK/metrics.json" >/dev/null
printf '{"baseline":{"cost_per_outcome":100,"retry_rate":10},"current":{"cost_per_outcome":140,"retry_rate":11}}\n' > "$WORK/metrics-bad.json"
if python3 "$DIR/check-token-regression.py" "$WORK/metrics-bad.json" >/dev/null 2>&1; then
    echo "efficiency-gates.test: regression ratchet did not fail" >&2
    exit 1
fi
echo "efficiency-gates.test: PASS"
