#!/usr/bin/env python3
# SPDX-FileCopyrightText: 2026 Mattia Egloff <mattia.egloff@pm.me>
# SPDX-License-Identifier: GPL-3.0-or-later

"""Shared contracts for local, privacy-preserving agent telemetry."""

from __future__ import annotations

import hashlib
import hmac
import json
import os
import subprocess
import tempfile
from pathlib import Path
from typing import Any, Iterable

SCHEMA_VERSION = 1
SESSION_TYPES = frozenset(
    {"implementation", "investigation", "review", "operations"}
)
OUTCOMES = frozenset(
    {"completed", "resolved", "confirmed", "aborted", "unknown"}
)


def discover_workspace_root(private_checkout: Path) -> Path:
    """Resolve the primary workspace from a normal or linked `_private` checkout."""
    result = subprocess.run(
        [
            "git",
            "rev-parse",
            "--path-format=absolute",
            "--git-common-dir",
        ],
        cwd=private_checkout,
        capture_output=True,
        text=True,
        check=False,
    )
    if result.returncode != 0:
        raise ValueError(f"cannot resolve git common directory: {result.stderr.strip()}")
    common_git_directory = Path(result.stdout.strip()).resolve()
    private_root = common_git_directory.parent
    if private_root.name != "_private":
        raise ValueError(
            f"expected _private git common directory, got {common_git_directory}"
        )
    return private_root.parent.resolve()


def hashed_identifier(value: str, salt: bytes) -> str:
    return hmac.new(salt, value.encode("utf-8"), hashlib.sha256).hexdigest()[:24]


def normalized_event(
    *,
    agent: str,
    session_id: str,
    salt: bytes,
    sequence: int,
    timestamp: str,
    kind: str,
    **fields: Any,
) -> dict[str, Any]:
    return {
        "schema": SCHEMA_VERSION,
        "agent": agent,
        "session_key": hashed_identifier(session_id, salt),
        "sequence": sequence,
        "timestamp": timestamp,
        "kind": kind,
        **fields,
    }


def write_jsonl_atomic(path: Path, records: Iterable[dict[str, Any]]) -> None:
    path.parent.mkdir(parents=True, exist_ok=True, mode=0o700)
    os.chmod(path.parent, 0o700)
    descriptor, temporary_name = tempfile.mkstemp(
        dir=path.parent, prefix=f".{path.name}.", text=True
    )
    temporary_path = Path(temporary_name)
    try:
        with os.fdopen(descriptor, "w", encoding="utf-8") as handle:
            for record in records:
                handle.write(
                    json.dumps(record, sort_keys=True, separators=(",", ":"))
                )
                handle.write("\n")
            handle.flush()
            os.fsync(handle.fileno())
        os.chmod(temporary_path, 0o600)
        os.replace(temporary_path, path)
        os.chmod(path, 0o600)
    finally:
        if temporary_path.exists():
            temporary_path.unlink()


def append_receipt(
    path: Path,
    *,
    session_id: str,
    session_type: str,
    outcome: str,
    corrections: int,
    salt: bytes,
) -> dict[str, Any]:
    if session_type not in SESSION_TYPES:
        raise ValueError(f"invalid session type: {session_type}")
    if outcome not in OUTCOMES:
        raise ValueError(f"invalid outcome: {outcome}")
    if not isinstance(corrections, int) or corrections < 0:
        raise ValueError("corrections must be a non-negative integer")
    receipt = {
        "schema": SCHEMA_VERSION,
        "session_key": hashed_identifier(session_id, salt),
        "session_type": session_type,
        "outcome": outcome,
        "corrections": corrections,
    }
    path.parent.mkdir(parents=True, exist_ok=True, mode=0o700)
    os.chmod(path.parent, 0o700)
    descriptor = os.open(path, os.O_WRONLY | os.O_APPEND | os.O_CREAT, 0o600)
    with os.fdopen(descriptor, "a", encoding="utf-8") as handle:
        handle.write(json.dumps(receipt, sort_keys=True, separators=(",", ":")))
        handle.write("\n")
        handle.flush()
        os.fsync(handle.fileno())
    os.chmod(path, 0o600)
    return receipt


def read_jsonl(path: Path) -> list[dict[str, Any]]:
    records: list[dict[str, Any]] = []
    if not path.exists():
        return records
    with path.open(encoding="utf-8", errors="replace") as handle:
        for line in handle:
            try:
                record = json.loads(line)
            except json.JSONDecodeError:
                continue
            if isinstance(record, dict):
                records.append(record)
    return records
