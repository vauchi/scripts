#!/usr/bin/env python3
# SPDX-FileCopyrightText: 2026 Mattia Egloff <mattia.egloff@pm.me>
# SPDX-License-Identifier: GPL-3.0-or-later

"""Discover native sessions and backfill normalized local timelines."""

from __future__ import annotations

import json
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
    project_match: str = ""


def backfill(config: BackfillConfig) -> dict[str, Any]:
    workspace = config.workspace_root.resolve()
    project_match = config.project_match or workspace.name
    salt = load_or_create_salt(config.salt_file)
    events: list[dict[str, Any]] = []
    session_ids: dict[str, set[str]] = {
        "claude": set(),
        "kimi": set(),
        "codex": set(),
    }
    streams = {"claude": 0, "kimi": 0, "codex": 0}

    for path in (config.claude_home / "projects").rglob("*.jsonl"):
        records = read_jsonl(path)
        if not _claude_session_matches(
            records,
            path,
            config.claude_home,
            workspace,
            project_match,
            config.since,
        ):
            continue
        session_id = _first_string(records, "sessionId") or path.stem
        agent_id = _first_string(records, "agentId")
        is_subagent = "subagents" in path.parts
        stream_id = (
            f"{session_id}:agent:{agent_id or path.stem}"
            if is_subagent
            else session_id
        )
        normalized = normalize_claude(
            records,
            stream_id,
            salt,
            role="subagent" if is_subagent else "main",
            parent_session_id=session_id if is_subagent else None,
        )
        if normalized:
            events.extend(normalized)
            session_ids["claude"].add(session_id)
            streams["claude"] += 1

    for session in read_jsonl(config.kimi_home / "session_index.jsonl"):
        session_directory = Path(str(session.get("sessionDir") or ""))
        if not _matches_project(
            session.get("workDir"), workspace, project_match
        ) and project_match not in str(session_directory):
            continue
        created_at = _parse_timestamp(session.get("createdAt"))
        if created_at is None:
            state = _read_json_object(session_directory / "state.json")
            created_at = _parse_timestamp(state.get("createdAt"))
        if created_at is None or created_at < config.since:
            continue
        session_id = str(session.get("sessionId") or session_directory.name)
        for wire in sorted((session_directory / "agents").glob("*/wire.jsonl")):
            agent_name = wire.parent.name
            is_subagent = agent_name != "main"
            normalized = normalize_kimi(
                read_jsonl(wire),
                f"{session_id}:{agent_name}" if is_subagent else session_id,
                salt,
                role="subagent" if is_subagent else "main",
                parent_session_id=session_id if is_subagent else None,
            )
            if normalized:
                events.extend(normalized)
                session_ids["kimi"].add(session_id)
                streams["kimi"] += 1

    codex_streams: list[
        tuple[Path, list[dict[str, Any]], dict[str, Any], str]
    ] = []
    codex_parents: dict[str, str] = {}
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
        if not _matches_project(metadata.get("cwd"), workspace, project_match):
            continue
        created_at = _parse_timestamp(
            metadata.get("timestamp") or _first_string(records, "timestamp")
        )
        if created_at is None or created_at < config.since:
            continue
        session_id = str(metadata.get("id") or path.stem)
        parent_session_id = str(metadata.get("parent_thread_id") or "")
        codex_streams.append((path, records, metadata, session_id))
        if parent_session_id:
            codex_parents[session_id] = parent_session_id

    for _path, records, metadata, session_id in codex_streams:
        parent_session_id = str(metadata.get("parent_thread_id") or "")
        normalized = normalize_codex(
            records,
            session_id,
            salt,
            role="subagent" if parent_session_id else "main",
            parent_session_id=parent_session_id or None,
        )
        if normalized:
            events.extend(normalized)
            session_ids["codex"].add(
                _root_session_id(session_id, codex_parents)
            )
            streams["codex"] += 1

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
        "sessions": {
            agent: len(identifiers)
            for agent, identifiers in session_ids.items()
        },
        "streams": streams,
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
    records: list[dict[str, Any]],
    source: Path,
    claude_home: Path,
    workspace: Path,
    project_match: str,
    since: datetime,
) -> bool:
    source_matches = project_match in str(source.relative_to(claude_home))
    cwd_matches = any(
        _matches_project(record.get("cwd"), workspace, project_match)
        for record in records
    )
    if not source_matches and not cwd_matches:
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


def _matches_project(raw_path: Any, workspace: Path, project_match: str) -> bool:
    return _path_within(raw_path, workspace) or (
        isinstance(raw_path, str) and project_match in raw_path
    )


def _read_json_object(path: Path) -> dict[str, Any]:
    records = read_jsonl(path)
    if records:
        return records[0]
    try:
        value = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, ValueError):
        return {}
    return value if isinstance(value, dict) else {}


def _first_string(records: list[dict[str, Any]], key: str) -> str:
    for record in records:
        value = record.get(key)
        if isinstance(value, str) and value:
            return value
    return ""


def _root_session_id(session_id: str, parents: dict[str, str]) -> str:
    seen: set[str] = set()
    current = session_id
    while current in parents and current not in seen:
        seen.add(current)
        current = parents[current]
    return current


def _parse_timestamp(value: Any) -> datetime | None:
    if not isinstance(value, str):
        return None
    try:
        return datetime.fromisoformat(value.replace("Z", "+00:00"))
    except ValueError:
        return None
