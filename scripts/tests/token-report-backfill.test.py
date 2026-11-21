#!/usr/bin/env python3
# SPDX-FileCopyrightText: 2026 Mattia Egloff <mattia.egloff@pm.me>
# SPDX-License-Identifier: GPL-3.0-or-later

"""End-to-end contracts for token-report backfill and receipts."""

import importlib.util
import json
import os
import subprocess
import tempfile
import unittest
from pathlib import Path

SCRIPT_DIR = Path(__file__).resolve().parents[1]
TOKEN_REPORT = SCRIPT_DIR / "token-report.py"
SPEC = importlib.util.spec_from_file_location("token_report", TOKEN_REPORT)
assert SPEC and SPEC.loader
MODULE = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(MODULE)


class LegacySummaryTests(unittest.TestCase):
    def test_claude_summary_counts_one_streamed_message_once(self) -> None:
        with tempfile.TemporaryDirectory() as temporary_directory:
            claude_home = Path(temporary_directory)
            project = claude_home / "projects/-workspace-vauchi"
            project.mkdir(parents=True)
            usage = {
                "input_tokens": 10,
                "cache_read_input_tokens": 20,
                "cache_creation_input_tokens": 30,
                "output_tokens": 40,
            }
            record = {
                "type": "assistant",
                "timestamp": "2026-07-23T08:00:00Z",
                "message": {"id": "m1", "model": "claude", "usage": usage},
            }
            _write_jsonl(project / "session.jsonl", [record, record])

            per_day, files, nested = MODULE.token_side(
                "vauchi", claude_home=claude_home
            )

            self.assertEqual(files, 1)
            self.assertEqual(nested, 0)
            self.assertEqual(per_day["2026-07-23"]["msgs"], 1)
            self.assertEqual(per_day["2026-07-23"]["out"], 40)

    def test_kimi_summary_reads_current_usage_record(self) -> None:
        with tempfile.TemporaryDirectory() as temporary_directory:
            kimi_home = Path(temporary_directory)
            wire = (
                kimi_home
                / "sessions/wd_workspace_vauchi_hash/session_test/agents/main"
                / "wire.jsonl"
            )
            _write_jsonl(
                wire,
                [
                    {
                        "type": "usage.record",
                        "model": "kimi",
                        "time": 1_753_257_600_000,
                        "usage": {
                            "inputOther": 10,
                            "inputCacheRead": 20,
                            "inputCacheCreation": 30,
                            "output": 40,
                        },
                    }
                ],
            )

            per_day, files, nested = MODULE.kimi_token_side(
                "vauchi", kimi_home=kimi_home
            )

            self.assertEqual(files, 1)
            self.assertEqual(nested, 0)
            self.assertEqual(per_day["2025-07-23"]["msgs"], 1)
            self.assertEqual(per_day["2025-07-23"]["out"], 40)


class BackfillCommandTests(unittest.TestCase):
    def test_backfill_discovers_all_agents_without_persisting_bodies(self) -> None:
        with tempfile.TemporaryDirectory() as temporary_directory:
            root = Path(temporary_directory)
            workspace = root / "vauchi"
            workspace.mkdir()
            claude_home = root / "claude"
            kimi_home = root / "kimi"
            codex_home = root / "codex"
            output = workspace / "tmp/session-telemetry/timeline-v1.jsonl"
            salt_file = workspace / "tmp/session-telemetry/.salt"
            self._write_claude(claude_home, workspace)
            self._write_kimi(kimi_home, workspace)
            self._write_codex(codex_home, workspace)

            result = subprocess.run(
                [
                    "python3",
                    str(TOKEN_REPORT),
                    "backfill",
                    "--since",
                    "2026-07-22",
                    "--workspace-root",
                    str(workspace),
                    "--output",
                    str(output),
                    "--salt-file",
                    str(salt_file),
                    "--claude-home",
                    str(claude_home),
                    "--kimi-home",
                    str(kimi_home),
                    "--codex-home",
                    str(codex_home),
                ],
                capture_output=True,
                text=True,
                check=False,
            )

            self.assertEqual(result.returncode, 0, result.stderr)
            summary = json.loads(result.stdout)
            self.assertEqual(summary["sessions"], {"claude": 1, "codex": 1, "kimi": 1})
            self.assertEqual(summary["streams"], {"claude": 1, "codex": 1, "kimi": 2})
            records = [
                json.loads(line) for line in output.read_text(encoding="utf-8").splitlines()
            ]
            serialized = json.dumps(records)
            self.assertEqual({record["agent"] for record in records}, {
                "claude",
                "codex",
                "kimi",
            })
            self.assertNotIn("PROMPT-SECRET", serialized)
            self.assertNotIn("RESULT-SECRET", serialized)
            self.assertNotIn(str(workspace), serialized)
            kimi_records = [
                record for record in records if record["agent"] == "kimi"
            ]
            main_key = next(
                record["session_key"]
                for record in kimi_records
                if record["role"] == "main"
            )
            subagent = next(
                record
                for record in kimi_records
                if record["role"] == "subagent"
            )
            self.assertEqual(subagent["parent_session_key"], main_key)

            first = output.read_bytes()
            repeated = subprocess.run(
                result.args, capture_output=True, text=True, check=False
            )
            self.assertEqual(repeated.returncode, 0, repeated.stderr)
            self.assertEqual(output.read_bytes(), first)

    def test_receipt_command_persists_validated_local_outcome(self) -> None:
        with tempfile.TemporaryDirectory() as temporary_directory:
            root = Path(temporary_directory)
            output = root / "receipts.jsonl"
            salt_file = root / ".salt"

            result = subprocess.run(
                [
                    "python3",
                    str(TOKEN_REPORT),
                    "receipt",
                    "--session",
                    "session-secret",
                    "--type",
                    "review",
                    "--outcome",
                    "confirmed",
                    "--corrections",
                    "0",
                    "--output",
                    str(output),
                    "--salt-file",
                    str(salt_file),
                ],
                capture_output=True,
                text=True,
                check=False,
            )

            self.assertEqual(result.returncode, 0, result.stderr)
            receipt = json.loads(result.stdout)
            self.assertEqual(receipt["session_type"], "review")
            self.assertEqual(receipt["outcome"], "confirmed")
            self.assertNotIn("session-secret", output.read_text(encoding="utf-8"))

    def _write_claude(self, home: Path, workspace: Path) -> None:
        project = home / "projects/-workspace-vauchi"
        record = {
            "type": "assistant",
            "sessionId": "claude-session",
            "cwd": "/private/agent-worktrees/vauchi-copy",
            "timestamp": "2026-07-23T08:00:00Z",
            "message": {
                "id": "m1",
                "usage": {"input_tokens": 1, "output_tokens": 2},
                "content": [{"type": "text", "text": "PROMPT-SECRET"}],
            },
        }
        _write_jsonl(project / "session.jsonl", [record])

    def _write_kimi(self, home: Path, workspace: Path) -> None:
        session = home / "sessions/wd_workspace_vauchi_hash/session_test"
        index = {
            "sessionId": "kimi-session",
            "sessionDir": str(session),
            "workDir": "/private/agent-worktrees/vauchi-copy",
        }
        _write_jsonl(home / "session_index.jsonl", [index])
        (session / "state.json").parent.mkdir(parents=True, exist_ok=True)
        (session / "state.json").write_text(
            json.dumps({"createdAt": "2026-07-23T08:00:00Z"}),
            encoding="utf-8",
        )
        records = [{
                "type": "usage.record",
                "time": 1_753_257_600_000,
                "usage": {"inputOther": 1, "output": 2},
        }]
        _write_jsonl(session / "agents/main/wire.jsonl", records)
        _write_jsonl(session / "agents/reviewer/wire.jsonl", records)

    def _write_codex(self, home: Path, workspace: Path) -> None:
        records = [
            {
                "type": "session_meta",
                "timestamp": "2026-07-23T08:00:00Z",
                "payload": {
                    "id": "codex-session",
                    "cwd": "/private/agent-worktrees/vauchi-copy",
                    "timestamp": "2026-07-23T08:00:00Z",
                },
            },
            {
                "type": "event_msg",
                "timestamp": "2026-07-23T08:01:00Z",
                "payload": {
                    "type": "token_count",
                    "info": {
                        "total_token_usage": {
                            "input_tokens": 3,
                            "cached_input_tokens": 0,
                            "output_tokens": 2,
                        },
                        "last_token_usage": {
                            "input_tokens": 3,
                            "cached_input_tokens": 0,
                            "output_tokens": 2,
                        },
                    },
                },
            },
            {
                "type": "response_item",
                "timestamp": "2026-07-23T08:01:01Z",
                "payload": {
                    "type": "function_call_output",
                    "output": "RESULT-SECRET",
                },
            },
        ]
        _write_jsonl(home / "sessions/2026/07/23/rollout-test.jsonl", records)


def _write_jsonl(path: Path, records: list[dict]) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(
        "".join(json.dumps(record) + "\n" for record in records),
        encoding="utf-8",
    )


if __name__ == "__main__":
    unittest.main()
