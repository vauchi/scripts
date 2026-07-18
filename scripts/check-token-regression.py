#!/usr/bin/env python3
# SPDX-FileCopyrightText: 2026 Mattia Egloff <mattia.egloff@pm.me>
# SPDX-License-Identifier: GPL-3.0-or-later
"""Check comparable efficiency metrics against a percentage ratchet."""
from __future__ import annotations
import json
import sys
from pathlib import Path

def main() -> int:
    if len(sys.argv) < 2:
        print("usage: check-token-regression.py METRICS.json [max_delta_percent]", file=sys.stderr)
        return 2
    data = json.loads(Path(sys.argv[1]).read_text(encoding="utf-8"))
    threshold = float(sys.argv[2]) if len(sys.argv) > 2 else 25.0
    failures = 0
    for metric in ("cost_per_outcome", "retry_rate"):
        baseline = data.get("baseline", {}).get(metric)
        current = data.get("current", {}).get(metric)
        if baseline is None or current is None or baseline == 0:
            print(f"token-regression: {metric} not comparable; advisory only")
            continue
        delta = (float(current) - float(baseline)) / float(baseline) * 100
        print(f"token-regression: {metric} {delta:+.1f}%")
        if delta > threshold:
            print(f"token-regression: {metric} exceeds {threshold:.1f}% ratchet", file=sys.stderr)
            failures += 1
    return 1 if failures else 0

if __name__ == "__main__":
    raise SystemExit(main())
