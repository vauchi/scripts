#!/usr/bin/env python3
# SPDX-FileCopyrightText: 2026 Mattia Egloff <mattia.egloff@pm.me>
# SPDX-License-Identifier: GPL-3.0-or-later

import json
import sys
from pathlib import Path


VALID_SEVERITIES = {"critical", "high", "medium", "low", "unknown", "info"}


def load_findings(report_path: Path) -> list[dict[str, object]]:
    try:
        report = json.loads(report_path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError) as error:
        raise ValueError(f"cannot read SAST report: {error}") from error

    findings = report.get("vulnerabilities") if isinstance(report, dict) else None
    if not isinstance(findings, list):
        raise ValueError("SAST report has no vulnerability list")

    for finding in findings:
        if not isinstance(finding, dict):
            raise ValueError("SAST report contains a malformed finding")
        severity = finding.get("severity")
        if not isinstance(severity, str) or severity.lower() not in VALID_SEVERITIES:
            raise ValueError("SAST finding has no valid severity")

    return findings


def main() -> int:
    if len(sys.argv) != 2:
        print(f"Usage: {Path(sys.argv[0]).name} <gl-sast-report.json>", file=sys.stderr)
        return 2

    try:
        findings = load_findings(Path(sys.argv[1]))
    except ValueError as error:
        print(f"ERROR: {error}", file=sys.stderr)
        return 2

    critical = [finding for finding in findings if finding["severity"].lower() == "critical"]
    if critical:
        print(f"BLOCKED: SAST report contains {len(critical)} Critical finding(s).")
        for finding in critical:
            evidence = {key: finding[key] for key in ("id", "name") if key in finding}
            print(json.dumps(evidence, ensure_ascii=True, sort_keys=True))
        return 1

    print("SAST severity gate passed: no Critical findings.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
