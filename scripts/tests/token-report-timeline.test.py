#!/usr/bin/env python3
# SPDX-FileCopyrightText: 2026 Mattia Egloff <mattia.egloff@pm.me>
# SPDX-License-Identifier: GPL-3.0-or-later

"""Contract tests for privacy-preserving multi-agent session timelines."""

import json
import os
import stat
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

SCRIPT_DIR = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(SCRIPT_DIR))

import agent_telemetry  # noqa: E402
import agent_telemetry_adapters  # noqa: E402


class WorkspaceDiscoveryTests(unittest.TestCase):
    def test_discover_workspace_root_from_private_worktree(self) -> None:
        with tempfile.TemporaryDirectory() as temporary_directory:
            workspace = Path(temporary_directory) / "vauchi"
            private = workspace / "_private"
            private.mkdir(parents=True)
            subprocess.run(["git", "init", "-q"], cwd=private, check=True)
            subprocess.run(
                ["git", "config", "user.email", "test@example.invalid"],
                cwd=private,
                check=True,
            )
            subprocess.run(
                ["git", "config", "user.name", "Test"],
                cwd=private,
                check=True,
            )
            marker = private / "marker"
            marker.write_text("test", encoding="utf-8")
            subprocess.run(["git", "add", "marker"], cwd=private, check=True)
            subprocess.run(
                ["git", "commit", "-q", "-m", "test: initial"],
                cwd=private,
                check=True,
            )
            linked = workspace / ".worktrees/test/_private"
            linked.parent.mkdir(parents=True)
            subprocess.run(
                ["git", "worktree", "add", "-q", "-b", "test", str(linked)],
                cwd=private,
                check=True,
            )

            actual = agent_telemetry.discover_workspace_root(linked)

            self.assertEqual(actual, workspace.resolve())


class AdapterContractTests(unittest.TestCase):
    def test_claude_deduplicates_streaming_snapshots_and_classifies_reads(
        self,
    ) -> None:
        usage = {
            "input_tokens": 10,
            "cache_read_input_tokens": 20,
            "cache_creation_input_tokens": 30,
            "output_tokens": 40,
        }
        records = [
            _claude_assistant("m1", "t1", "Read", "/secret/card.rs", usage),
            _claude_assistant("m1", "t1", "Read", "/secret/card.rs", usage),
            _claude_assistant("m2", "t2", "Edit", "/secret/card.rs", usage),
            _claude_assistant("m3", "t3", "Read", "/secret/card.rs", usage),
        ]

        events = agent_telemetry_adapters.normalize_claude(
            records, "session-secret", b"test-salt"
        )

        usage_events = [event for event in events if event["kind"] == "usage"]
        read_events = [
            event
            for event in events
            if event["kind"] == "tool" and event["tool"] == "Read"
        ]
        serialized = json.dumps(events)
        self.assertEqual(len(usage_events), 3)
        self.assertEqual(len(read_events), 2)
        self.assertEqual(read_events[0]["classification"], "first_read")
        self.assertEqual(
            read_events[1]["classification"], "post_edit_verification"
        )
        self.assertNotIn("session-secret", serialized)
        self.assertNotIn("/secret/card.rs", serialized)

    def test_kimi_current_and_legacy_usage_shapes_normalize_equally(self) -> None:
        usage = {
            "inputOther": 10,
            "inputCacheRead": 20,
            "inputCacheCreation": 30,
            "output": 40,
        }
        current = {
            "type": "usage.record",
            "model": "kimi",
            "usage": usage,
            "time": 1_753_257_600_000,
        }
        legacy = {
            "event": {"model": "kimi", "usage": usage},
            "time": 1_753_257_600_000,
        }

        current_events = agent_telemetry_adapters.normalize_kimi(
            [current], "current", b"salt"
        )
        legacy_events = agent_telemetry_adapters.normalize_kimi(
            [legacy], "legacy", b"salt"
        )

        self.assertEqual(current_events[0]["usage"], legacy_events[0]["usage"])
        self.assertEqual(current_events[0]["timestamp"], "2025-07-23T08:00:00Z")

    def test_kimi_emits_body_free_wait_and_retry_signals(self) -> None:
        records = [
            {
                "type": "context.append_loop_event",
                "time": 1_753_257_600_000,
                "event": {
                    "type": "tool.call",
                    "name": "Bash",
                    "args": {"command": "sleep 10; echo COMMAND-SECRET"},
                },
            },
            {
                "type": "context.append_loop_event",
                "time": 1_753_257_601_000,
                "event": {
                    "type": "tool.result",
                    "result": {"output": "retry RESULT-SECRET"},
                },
            },
        ]

        events = agent_telemetry_adapters.normalize_kimi(
            records, "kimi", b"salt"
        )

        self.assertEqual(events[0]["classification"], "wait")
        self.assertEqual(events[1]["kind"], "retry")
        serialized = json.dumps(events)
        self.assertNotIn("COMMAND-SECRET", serialized)
        self.assertNotIn("RESULT-SECRET", serialized)

    def test_codex_deduplicates_cumulative_snapshots_and_marks_compaction(
        self,
    ) -> None:
        usage = {
            "input_tokens": 100,
            "cached_input_tokens": 70,
            "output_tokens": 20,
            "reasoning_output_tokens": 5,
            "total_tokens": 120,
        }
        records = [
            _codex_usage("2026-07-23T08:00:00Z", usage),
            _codex_usage("2026-07-23T08:00:01Z", usage),
            {
                "type": "event_msg",
                "timestamp": "2026-07-23T08:00:02Z",
                "payload": {"type": "context_compacted"},
            },
        ]

        events = agent_telemetry_adapters.normalize_codex(
            records, "codex-secret", b"salt"
        )

        usage_events = [event for event in events if event["kind"] == "usage"]
        compact_events = [
            event for event in events if event["kind"] == "compaction"
        ]
        self.assertEqual(len(usage_events), 1)
        self.assertEqual(
            usage_events[0]["usage"],
            {
                "input": 30,
                "cached_input": 70,
                "cache_creation": 0,
                "output": 20,
                "reasoning_output": 5,
            },
        )
        self.assertEqual(len(compact_events), 1)

    def test_codex_marks_wait_tools_without_retaining_arguments(self) -> None:
        records = [
            {
                "type": "response_item",
                "timestamp": "2026-07-23T08:00:00Z",
                "payload": {
                    "type": "function_call",
                    "name": "wait_agent",
                    "arguments": '{"secret":"ARGUMENT-SECRET"}',
                },
            }
        ]

        events = agent_telemetry_adapters.normalize_codex(
            records, "codex", b"salt"
        )

        self.assertEqual(events[0]["classification"], "wait")
        self.assertNotIn("ARGUMENT-SECRET", json.dumps(events))


class LocalOutputTests(unittest.TestCase):
    def test_write_jsonl_atomic_is_deterministic_and_private(self) -> None:
        events = [
            {
                "schema": 1,
                "agent": "claude",
                "session_key": "abc",
                "sequence": 0,
                "timestamp": "2026-07-23T08:00:00Z",
                "kind": "compaction",
            }
        ]
        with tempfile.TemporaryDirectory() as temporary_directory:
            output = Path(temporary_directory) / "timeline/events.jsonl"

            agent_telemetry.write_jsonl_atomic(output, events)
            first = output.read_bytes()
            agent_telemetry.write_jsonl_atomic(output, events)

            self.assertEqual(output.read_bytes(), first)
            self.assertEqual(stat.S_IMODE(output.stat().st_mode), 0o600)
            self.assertEqual(stat.S_IMODE(output.parent.stat().st_mode), 0o700)

    def test_append_receipt_validates_and_omits_free_text(self) -> None:
        with tempfile.TemporaryDirectory() as temporary_directory:
            output = Path(temporary_directory) / "receipts.jsonl"

            receipt = agent_telemetry.append_receipt(
                output,
                session_id="session-secret",
                session_type="investigation",
                outcome="resolved",
                corrections=0,
                salt=b"salt",
            )

            persisted = json.loads(output.read_text(encoding="utf-8"))
            self.assertEqual(persisted, receipt)
            self.assertEqual(persisted["session_type"], "investigation")
            self.assertEqual(persisted["outcome"], "resolved")
            self.assertEqual(persisted["corrections"], 0)
            self.assertNotIn("session-secret", json.dumps(persisted))
            with self.assertRaisesRegex(ValueError, "session type"):
                agent_telemetry.append_receipt(
                    output,
                    session_id="id",
                    session_type="unknown",
                    outcome="resolved",
                    corrections=0,
                    salt=b"salt",
                )


def _claude_assistant(
    message_id: str,
    tool_id: str,
    tool: str,
    path: str,
    usage: dict[str, int],
) -> dict:
    return {
        "type": "assistant",
        "timestamp": "2026-07-23T08:00:00Z",
        "message": {
            "id": message_id,
            "model": "claude",
            "usage": usage,
            "content": [
                {
                    "type": "tool_use",
                    "id": tool_id,
                    "name": tool,
                    "input": {"file_path": path, "new_string": "private-body"},
                }
            ],
        },
    }


def _codex_usage(timestamp: str, usage: dict[str, int]) -> dict:
    return {
        "type": "event_msg",
        "timestamp": timestamp,
        "payload": {
            "type": "token_count",
            "info": {
                "total_token_usage": usage,
                "last_token_usage": usage,
            },
        },
    }


if __name__ == "__main__":
    unittest.main()
