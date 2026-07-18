#!/usr/bin/env python3
# SPDX-FileCopyrightText: 2026 Mattia Egloff <mattia.egloff@pm.me>
# SPDX-License-Identifier: GPL-3.0-or-later
"""Fail on long verbatim instruction duplication between root guidance files."""
from __future__ import annotations
import sys
from pathlib import Path

def meaningful_lines(path: Path) -> set[str]:
    return {
        line.strip()
        for line in path.read_text(encoding="utf-8").splitlines()
        if len(line.strip()) >= 80
        and not line.strip().startswith("<!--")
        and not line.strip().startswith("```")
    }

def main() -> int:
    root = Path(sys.argv[1] if len(sys.argv) > 1 else ".")
    agents, claude = root / "AGENTS.md", root / "CLAUDE.md"
    if not agents.exists() or not claude.exists():
        print("instruction-overlap: required guidance file missing", file=sys.stderr)
        return 1
    overlap = sorted(meaningful_lines(agents) & meaningful_lines(claude))
    for line in overlap:
        print(f"instruction-overlap: duplicated line: {line}", file=sys.stderr)
    return 1 if overlap else 0

if __name__ == "__main__":
    raise SystemExit(main())
