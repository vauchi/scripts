#!/usr/bin/env python3
# SPDX-FileCopyrightText: 2026 Mattia Egloff <mattia.egloff@pm.me>
# SPDX-License-Identifier: GPL-3.0-or-later

"""Normalize native agent events without retaining their bodies."""

from __future__ import annotations

from datetime import datetime, timezone
from typing import Any, Iterable

from agent_telemetry import hashed_identifier, normalized_event


def normalize_claude(
    records: Iterable[dict[str, Any]],
    session_id: str,
    salt: bytes,
    *,
    role: str = "main",
    parent_session_id: str | None = None,
) -> list[dict[str, Any]]:
    events: list[dict[str, Any]] = []
    seen_messages: set[str] = set()
    seen_tools: set[str] = set()
    last_reads: set[str] = set()
    edited_targets: set[str] = set()
    uncertain_mutation = False

    for record in records:
        timestamp = _iso_timestamp(record.get("timestamp"))
        if (
            record.get("type") == "system"
            and record.get("subtype") == "compact_boundary"
        ):
            _append(events, "claude", session_id, salt, timestamp, "compaction")
            continue
        if record.get("type") != "assistant":
            continue
        message = record.get("message") or {}
        message_id = str(message.get("id") or "")
        if message_id and message_id not in seen_messages:
            seen_messages.add(message_id)
            usage = _claude_usage(message.get("usage") or {})
            _append(
                events,
                "claude",
                session_id,
                salt,
                timestamp,
                "usage",
                usage=usage,
            )
        content = message.get("content") or []
        if not isinstance(content, list):
            continue
        for item in content:
            if not isinstance(item, dict) or item.get("type") != "tool_use":
                continue
            tool_id = str(item.get("id") or "")
            if tool_id and tool_id in seen_tools:
                continue
            if tool_id:
                seen_tools.add(tool_id)
            tool = str(item.get("name") or "unknown")
            tool_input = item.get("input") or {}
            target = _target_from_input(tool_input)
            target_key = hashed_identifier(target, salt) if target else None
            classification = None
            if tool == "Read" and target_key:
                if target_key not in last_reads:
                    classification = "first_read"
                elif target_key in edited_targets:
                    classification = "post_edit_verification"
                elif uncertain_mutation:
                    classification = "unknown_mutation"
                else:
                    classification = "no_observed_change"
                last_reads.add(target_key)
                edited_targets.discard(target_key)
                uncertain_mutation = False
            elif tool in {"Edit", "Write", "ApplyPatch", "apply_patch"}:
                if target_key:
                    edited_targets.add(target_key)
            elif tool in {"Bash", "exec", "exec_command"}:
                uncertain_mutation = True
                if _contains_wait(tool_input):
                    classification = "wait"
            fields: dict[str, Any] = {"tool": tool}
            if target_key:
                fields["target_key"] = target_key
            if classification:
                fields["classification"] = classification
            _append(
                events,
                "claude",
                session_id,
                salt,
                timestamp,
                "tool",
                **fields,
            )
    return _annotate_relationships(
        events, role=role, parent_session_id=parent_session_id, salt=salt
    )


def normalize_kimi(
    records: Iterable[dict[str, Any]],
    session_id: str,
    salt: bytes,
    *,
    role: str = "main",
    parent_session_id: str | None = None,
) -> list[dict[str, Any]]:
    events: list[dict[str, Any]] = []
    for record in records:
        timestamp = _iso_timestamp(record.get("time"))
        event = record.get("event") if isinstance(record.get("event"), dict) else {}
        usage = record.get("usage") if record.get("type") == "usage.record" else None
        if not isinstance(usage, dict):
            usage = event.get("usage")
        if isinstance(usage, dict):
            _append(
                events,
                "kimi",
                session_id,
                salt,
                timestamp,
                "usage",
                usage={
                    "input": _integer(usage.get("inputOther")),
                    "cached_input": _integer(usage.get("inputCacheRead")),
                    "cache_creation": _integer(usage.get("inputCacheCreation")),
                    "output": _integer(usage.get("output")),
                    "reasoning_output": 0,
                },
            )
            continue
        if record.get("type") == "full_compaction.complete":
            _append(events, "kimi", session_id, salt, timestamp, "compaction")
            continue
        loop_event = record.get("event") or {}
        if (
            record.get("type") == "context.append_loop_event"
            and loop_event.get("type") == "tool.call"
        ):
            tool = str(loop_event.get("name") or "unknown")
            fields: dict[str, Any] = {"tool": tool}
            if tool in {"TaskOutput", "wait"} or _contains_wait(
                loop_event.get("args")
            ):
                fields["classification"] = "wait"
            _append(
                events,
                "kimi",
                session_id,
                salt,
                timestamp,
                "tool",
                **fields,
            )
            continue
        if (
            record.get("type") == "context.append_loop_event"
            and loop_event.get("type") == "tool.result"
            and _contains_retry(loop_event.get("result"))
        ):
            _append(events, "kimi", session_id, salt, timestamp, "retry")
    return _annotate_relationships(
        events, role=role, parent_session_id=parent_session_id, salt=salt
    )


def normalize_codex(
    records: Iterable[dict[str, Any]],
    session_id: str,
    salt: bytes,
    *,
    role: str = "main",
    parent_session_id: str | None = None,
) -> list[dict[str, Any]]:
    events: list[dict[str, Any]] = []
    previous_cumulative: dict[str, Any] | None = None
    for record in records:
        timestamp = _iso_timestamp(record.get("timestamp"))
        payload = record.get("payload") or {}
        payload_type = payload.get("type")
        if record.get("type") == "event_msg" and payload_type == "token_count":
            info = payload.get("info") or {}
            cumulative = info.get("total_token_usage")
            usage = info.get("last_token_usage")
            if not isinstance(cumulative, dict) or not isinstance(usage, dict):
                continue
            deltas = {
                key: _usage_delta(cumulative, previous_cumulative, usage, key)
                for key in (
                    "input_tokens",
                    "cached_input_tokens",
                    "output_tokens",
                    "reasoning_output_tokens",
                )
            }
            previous_cumulative = cumulative
            if not any(deltas.values()):
                continue
            cached_input = deltas["cached_input_tokens"]
            input_tokens = deltas["input_tokens"]
            _append(
                events,
                "codex",
                session_id,
                salt,
                timestamp,
                "usage",
                usage={
                    "input": max(0, input_tokens - cached_input),
                    "cached_input": cached_input,
                    "cache_creation": 0,
                    "output": deltas["output_tokens"],
                    "reasoning_output": deltas["reasoning_output_tokens"],
                },
            )
            continue
        if payload_type == "context_compacted" or record.get("type") == "compacted":
            _append(events, "codex", session_id, salt, timestamp, "compaction")
            continue
        if record.get("type") == "response_item" and payload_type in {
            "function_call",
            "custom_tool_call",
        }:
            tool = str(payload.get("name") or "unknown")
            fields: dict[str, Any] = {"tool": tool}
            if tool in {"wait", "wait_agent", "write_stdin"}:
                fields["classification"] = "wait"
            _append(
                events,
                "codex",
                session_id,
                salt,
                timestamp,
                "tool",
                **fields,
            )
            continue
        if record.get("type") == "event_msg" and payload_type in {
            "task_complete",
            "turn_aborted",
        }:
            _append(
                events,
                "codex",
                session_id,
                salt,
                timestamp,
                "terminal",
                status="completed" if payload_type == "task_complete" else "aborted",
            )
    return _annotate_relationships(
        events, role=role, parent_session_id=parent_session_id, salt=salt
    )


def _annotate_relationships(
    events: list[dict[str, Any]],
    *,
    role: str,
    parent_session_id: str | None,
    salt: bytes,
) -> list[dict[str, Any]]:
    for event in events:
        event["role"] = role
        if parent_session_id:
            event["parent_session_key"] = hashed_identifier(
                parent_session_id, salt
            )
    return events


def _append(
    events: list[dict[str, Any]],
    agent: str,
    session_id: str,
    salt: bytes,
    timestamp: str,
    kind: str,
    **fields: Any,
) -> None:
    events.append(
        normalized_event(
            agent=agent,
            session_id=session_id,
            salt=salt,
            sequence=len(events),
            timestamp=timestamp,
            kind=kind,
            **fields,
        )
    )


def _claude_usage(usage: dict[str, Any]) -> dict[str, int]:
    cache_creation = usage.get("cache_creation") or {}
    cache_creation_total = _integer(usage.get("cache_creation_input_tokens"))
    if isinstance(cache_creation, dict) and cache_creation:
        cache_creation_total = sum(
            _integer(cache_creation.get(key))
            for key in (
                "ephemeral_5m_input_tokens",
                "ephemeral_1h_input_tokens",
            )
        )
    return {
        "input": _integer(usage.get("input_tokens")),
        "cached_input": _integer(usage.get("cache_read_input_tokens")),
        "cache_creation": cache_creation_total,
        "output": _integer(usage.get("output_tokens")),
        "reasoning_output": 0,
    }


def _target_from_input(tool_input: Any) -> str:
    if not isinstance(tool_input, dict):
        return ""
    for key in ("file_path", "path"):
        value = tool_input.get(key)
        if isinstance(value, str):
            return value
    return ""


def _contains_wait(value: Any) -> bool:
    if not isinstance(value, dict):
        return False
    command = value.get("command")
    if not isinstance(command, str):
        return False
    lowered = command.lower()
    return "sleep" in lowered or "wait" in lowered


def _contains_retry(value: Any) -> bool:
    if not isinstance(value, dict):
        return False
    output = value.get("output")
    return isinstance(output, str) and "retry" in output.lower()


def _usage_delta(
    cumulative: dict[str, Any],
    previous: dict[str, Any] | None,
    last: dict[str, Any],
    key: str,
) -> int:
    current_value = _integer(cumulative.get(key))
    if previous is None:
        return current_value
    previous_value = _integer(previous.get(key))
    if current_value >= previous_value:
        return current_value - previous_value
    return _integer(last.get(key))


def _integer(value: Any) -> int:
    return value if isinstance(value, int) and value >= 0 else 0


def _iso_timestamp(value: Any) -> str:
    if isinstance(value, int):
        timestamp = datetime.fromtimestamp(value / 1000, timezone.utc)
        return timestamp.isoformat().replace("+00:00", "Z")
    if isinstance(value, str):
        return value.replace("+00:00", "Z")
    return ""
