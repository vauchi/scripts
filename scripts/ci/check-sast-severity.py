#!/usr/bin/env python3
# SPDX-FileCopyrightText: 2026 Mattia Egloff <mattia.egloff@pm.me>
# SPDX-License-Identifier: GPL-3.0-or-later

import json
import re
import sys
from pathlib import Path


VALID_SEVERITIES = {"critical", "high", "medium", "low", "unknown", "info"}

# A rule that times out did not scan the file it gave up on, and semgrep
# still exits 0. Treating that as clean is how core MR !1547 reported no
# findings for a file vauchi-no-ring-direct never finished reading.
INCOMPLETE_SCAN = re.compile(r"time[d\s-]*out|timeout", re.IGNORECASE)

# semgrep reports incomplete analysis through SARIF notification descriptors,
# NOT through executionSuccessful — that stays true while rules give up on
# files (observed: 43 notifications, executionSuccessful true). These two mean
# a parseable file went unanalysed, which is the whole point of the gate.
BLOCKING_DESCRIPTORS = {"timeout", "out of memory"}


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


def load_notifications(sarif_path: Path) -> list[dict[str, object]] | None:
    """SARIF notifications, or None when there is no SARIF to read."""
    if not sarif_path.is_file():
        return None
    try:
        sarif = json.loads(sarif_path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError) as error:
        raise ValueError(f"cannot read SARIF: {error}") from error

    notifications = []
    for run in sarif.get("runs", []) if isinstance(sarif, dict) else []:
        for invocation in run.get("invocations", []) if isinstance(run, dict) else []:
            found = invocation.get("toolExecutionNotifications")
            if isinstance(found, list):
                notifications.extend(entry for entry in found if isinstance(entry, dict))
    return notifications


def describe(notification: dict[str, object]) -> tuple[str, str]:
    descriptor = notification.get("descriptor")
    kind = descriptor.get("id", "") if isinstance(descriptor, dict) else ""
    message = notification.get("message")
    text = message.get("text", "") if isinstance(message, dict) else ""
    return str(kind), " ".join(str(text).split())


def report_incomplete_analysis(notifications: list[dict[str, object]]) -> list[str]:
    """Notifications that mean a file was not analysed. Others are printed."""
    blocking, noted = [], []
    for notification in notifications:
        kind, text = describe(notification)
        if kind.lower() in BLOCKING_DESCRIPTORS or INCOMPLETE_SCAN.search(text):
            blocking.append(f"{kind}: {text}")
        else:
            noted.append(f"{kind}: {text}")

    for entry in noted:
        print(f"NOTE: analyzer reported {entry}")
    return blocking


def load_scan(report_path: Path) -> dict[str, object]:
    report = json.loads(report_path.read_text(encoding="utf-8"))
    scan = report.get("scan") if isinstance(report, dict) else None
    return scan if isinstance(scan, dict) else {}


def report_scan_completeness(scan: dict[str, object]) -> list[str]:
    """Reasons the scan cannot be trusted to have covered everything."""
    problems = []

    status = scan.get("status")
    if isinstance(status, str) and status.lower() != "success":
        problems.append(f"analyzer reported scan status {status!r}")

    messages = scan.get("messages")
    if not isinstance(messages, list):
        # GitLab's semgrep analyzer does not emit scan.messages — confirmed on
        # core!1548, where this branch printed on every run. SARIF carries the
        # incomplete-scan notifications instead; main() checks those.
        return problems

    for message in messages:
        value = message.get("value") if isinstance(message, dict) else None
        if isinstance(value, str) and INCOMPLETE_SCAN.search(value):
            problems.append(value)

    return problems


def main() -> int:
    if len(sys.argv) not in (2, 3):
        print(
            f"Usage: {Path(sys.argv[0]).name} <gl-sast-report.json> [semgrep.sarif]",
            file=sys.stderr,
        )
        return 2

    try:
        findings = load_findings(Path(sys.argv[1]))
    except ValueError as error:
        print(f"ERROR: {error}", file=sys.stderr)
        return 2

    sarif_path = Path(sys.argv[2] if len(sys.argv) == 3 else "semgrep.sarif")
    try:
        problems = report_scan_completeness(load_scan(Path(sys.argv[1])))
        notifications = load_notifications(sarif_path)
    except (OSError, json.JSONDecodeError, ValueError) as error:
        print(f"ERROR: cannot read SAST report: {error}", file=sys.stderr)
        return 2

    if notifications is None:
        print(f"NOTE: cannot verify rule timeouts — no SARIF at {sarif_path}.")
    else:
        problems.extend(report_incomplete_analysis(notifications))
        if not problems:
            print("SAST scan completeness: verified no rule timed out.")

    if problems:
        print(f"BLOCKED: SAST scan did not complete ({len(problems)} problem(s)).")
        for problem in problems:
            print(f"  {problem}")
        print("A file a rule timed out on was not scanned — that is unknown, not clean.")
        return 1

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
