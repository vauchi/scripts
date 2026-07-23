#!/usr/bin/env python3
# SPDX-FileCopyrightText: 2026 Mattia Egloff <mattia.egloff@pm.me>
# SPDX-License-Identifier: GPL-3.0-or-later

"""Discover native sessions and backfill normalized local timelines."""

from __future__ import annotations

import os
from dataclasses import dataclass
from datetime import datetime
from pathlib import Path
from typing import Any

from agent_telemetry import read_jsonl, write_jsonl_atomic
from agent_telemetry_adapters import (
    normalize_claude,
    normalize_codex,
    normalize_kimi,
)


@dataclass(frozen=True)
class BackfillConfig:
    workspace_root: Path
    since: datetime
    output: Path
    salt_file: Path
    claude_home: Path
    kimi_home: Path
    codex_home: Path


def backfill(config: BackfillConfig) -> dict[str, Any]:
    workspace = config.workspace_root.resolve()
    salt = load_or_create_salt(config.salt_file)
    events: list[dict[str, Any]] = []
    sessions = {"claude": 0, "kimi": 0, "codex": 0}

    for path in (config.claude_home / "projects").rglob("*.jsonl"):
        records = read_jsonl(path)
        if not _claude_session_matches(records, workspace, config.since):
            continue
        session_id = _first_string(records, "sessionId") or path.stem
        relative_source = str(path.relative_to(config.claude_home))
        normalized = normalize_claude(
            records, f"{session_id}:{relative_source}", salt
        )
        if normalized:
            events.extend(normalized)
            sessions["claude"] += 1

    for session in read_jsonl(config.kimi_home / "session_index.jsonl"):
        if not _path_within(session.get("workDir"), workspace):
            continue
        created_at = _parse_timestamp(session.get("createdAt"))
        if created_at is None or created_at < config.since:
            continue
        session_directory = Path(str(session.get("sessionDir") or ""))
        session_id = str(session.get("sessionId") or session_directory.name)
        for wire in sorted((session_directory / "agents").glob("*/wire.jsonl")):
            normalized = normalize_kimi(
                read_jsonl(wire), f"{session_id}:{wire.parent.name}", salt
            )
            if normalized:
                events.extend(normalized)
                sessions["kimi"] += 1

    for path in config.codex_home.joinpath("sessions").rglob("*.jsonl"):
        records = read_jsonl(path)
        metadata = next(
            (
                record.get("payload") or {}
                for record in records
                if record.get("type") == "session_meta"
            ),
            {},
        )
        if not _path_within(metadata.get("cwd"), workspace):
            continue
        created_at = _parse_timestamp(
            metadata.get("timestamp") or _first_string(records, "timestamp")
        )
        if created_at is None or created_at < config.since:
            continue
        session_id = str(metadata.get("id") or path.stem)
        normalized = normalize_codex(records, session_id, salt)
        if normalized:
            events.extend(normalized)
            sessions["codex"] += 1

    events.sort(
        key=lambda event: (
            event["timestamp"],
            event["agent"],
            event["session_key"],
            event["sequence"],
        )
    )
    write_jsonl_atomic(config.output, events)
    return {
        "schema": 1,
        "sessions": sessions,
        "events": len(events),
        "output": str(config.output),
    }


def load_or_create_salt(path: Path) -> bytes:
    path.parent.mkdir(parents=True, exist_ok=True, mode=0o700)
    os.chmod(path.parent, 0o700)
    if path.exists():
        salt = path.read_bytes()
        if len(salt) != 32:
            raise ValueError(f"telemetry salt must be 32 bytes: {path}")
        os.chmod(path, 0o600)
        return salt
    salt = os.urandom(32)
    descriptor = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
    with os.fdopen(descriptor, "wb") as handle:
        handle.write(salt)
        handle.flush()
        os.fsync(handle.fileno())
    os.chmod(path, 0o600)
    return salt


def _claude_session_matches(
    records: list[dict[str, Any]], workspace: Path, since: datetime
) -> bool:
    if not any(_path_within(record.get("cwd"), workspace) for record in records):
        return False
    timestamps = [
        parsed
        for record in records
        if (parsed := _parse_timestamp(record.get("timestamp"))) is not None
    ]
    return bool(timestamps and max(timestamps) >= since)


def _path_within(raw_path: Any, workspace: Path) -> bool:
    if not isinstance(raw_path, str) or not raw_path:
        return False
    try:
        Path(raw_path).resolve().relative_to(workspace)
    except (OSError, ValueError):
        return False
    return True


def _first_string(records: list[dict[str, Any]], key: str) -> str:
    for record in records:
        value = record.get(key)
        if isinstance(value, str) and value:
            return value
    return ""


def _parse_timestamp(value: Any) -> datetime | None:
    if not isinstance(value, str):
        return None
    try:
        return datetime.fromisoformat(value.replace("Z", "+00:00"))
    except ValueError:
        return None
