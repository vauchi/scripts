#!/usr/bin/env python3
# SPDX-FileCopyrightText: 2026 Mattia Egloff <mattia.egloff@pm.me>
#
# SPDX-License-Identifier: GPL-3.0-or-later

"""Wrap an arbitrary command with CodeCarbon and report emissions.

Example:
    python3 scripts/measure-carbon.py --project-name vauchi-core \
        --output-dir .cache/carbon -- cargo test -p vauchi-core

The wrapped command's exit code is preserved.
"""

from __future__ import annotations

import argparse
import json
import os
import subprocess
import sys
import time
from pathlib import Path
from typing import NoReturn


def parse_args(argv: list[str]) -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description="Measure carbon emissions of a command using CodeCarbon."
    )
    parser.add_argument(
        "--project-name",
        default="vauchi",
        help="Project name passed to CodeCarbon (default: vauchi).",
    )
    parser.add_argument(
        "--experiment-id",
        default=None,
        help="Optional experiment identifier for CodeCarbon.",
    )
    parser.add_argument(
        "--output-dir",
        default=".cache/carbon",
        help="Directory for CodeCarbon CSV/JSON output (default: .cache/carbon).",
    )
    parser.add_argument(
        "--format",
        choices=["text", "json"],
        default="text",
        help="Summary output format (default: text).",
    )
    parser.add_argument(
        "--allow-fallback",
        action="store_true",
        help="Run the command even if CodeCarbon cannot be imported.",
    )
    parser.add_argument(
        "command",
        nargs=argparse.REMAINDER,
        help="Command to run (prefix with '--' if it starts with '-').",
    )
    return parser.parse_args(argv)


def ensure_codecarbon() -> type:
    """Import CodeCarbon, raising a helpful error if it is missing."""
    try:
        from codecarbon import EmissionsTracker  # type: ignore[import-untyped]

        return EmissionsTracker
    except ImportError as exc:
        raise SystemExit(
            "Error: codecarbon is not installed.\n"
            "Install it with:\n"
            "  python3 -m pip install -r scripts/requirements-carbon.txt\n"
            "Or run with --allow-fallback to execute the command without measurement."
        ) from exc


def run_tracked(command: list[str], tracker_cls: type, output_dir: Path, project_name: str, experiment_id: str | None) -> tuple[int, dict]:
    """Run command under CodeCarbon and return (exit_code, metrics)."""
    output_dir.mkdir(parents=True, exist_ok=True)

    resolved_experiment_id = experiment_id or f"{project_name}-{int(time.time())}"
    tracker = tracker_cls(
        project_name=project_name,
        experiment_id=resolved_experiment_id,
        output_dir=str(output_dir),
        output_file="emissions.csv",
        measure_power_secs=1,
        save_to_file=True,
    )

    start_time = time.time()
    tracker.start()
    try:
        result = subprocess.run(command, check=False)
    finally:
        emissions = tracker.stop()
    elapsed = time.time() - start_time

    metrics = {
        "project_name": project_name,
        "experiment_id": resolved_experiment_id,
        "command": command,
        "duration_seconds": round(elapsed, 3),
        "emissions_kg_co2eq": emissions if emissions is not None else 0.0,
        "output_dir": str(output_dir),
    }
    return result.returncode, metrics


def print_summary(metrics: dict, fmt: str) -> None:
    if fmt == "json":
        print(json.dumps(metrics, indent=2))
        return

    print("══════════════════════════════════════════════════════════")
    print("  CodeCarbon Measurement Result")
    print("══════════════════════════════════════════════════════════")
    print(f"  Project:      {metrics['project_name']}")
    print(f"  Experiment:   {metrics['experiment_id']}")
    print(f"  Command:      {' '.join(metrics['command'])}")
    print(f"  Duration:     {metrics['duration_seconds']:.3f} s")
    print(f"  Emissions:    {metrics['emissions_kg_co2eq']:.9f} kg CO₂eq")
    print(f"  Output dir:   {metrics['output_dir']}")
    print("══════════════════════════════════════════════════════════")


def main(argv: list[str]) -> NoReturn:
    args = parse_args(argv)

    if not args.command:
        print("Error: no command provided.", file=sys.stderr)
        sys.exit(2)

    if args.command[0] == "--":
        command = args.command[1:]
    else:
        command = args.command

    if not command:
        print("Error: no command after optional '--'.", file=sys.stderr)
        sys.exit(2)

    try:
        tracker_cls = ensure_codecarbon()
    except SystemExit as exc:
        if args.allow_fallback:
            print(exc, file=sys.stderr)
            print("Warning: falling back to command execution without measurement.", file=sys.stderr)
            result = subprocess.run(command, check=False)
            sys.exit(result.returncode)
        raise

    exit_code, metrics = run_tracked(
        command=command,
        tracker_cls=tracker_cls,
        output_dir=Path(args.output_dir),
        project_name=args.project_name,
        experiment_id=args.experiment_id,
    )

    print_summary(metrics, args.format)

    if exit_code != 0:
        print(f"\nWarning: wrapped command exited with code {exit_code}.", file=sys.stderr)

    sys.exit(exit_code)


if __name__ == "__main__":
    main(sys.argv[1:])
