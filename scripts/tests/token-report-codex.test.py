#!/usr/bin/env python3
"""Contract tests for Codex metadata-only token aggregation."""

import importlib.util
import json
import tempfile
from pathlib import Path


MODULE_PATH = Path(__file__).resolve().parents[1] / "token-report.py"
SPEC = importlib.util.spec_from_file_location("token_report", MODULE_PATH)
assert SPEC and SPEC.loader
MODULE = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(MODULE)


def test_codex_token_side_uses_final_cumulative_usage() -> None:
    with tempfile.TemporaryDirectory() as temp:
        root = Path(temp)
        rollout = root / "sessions/2026/07/18/rollout-test.jsonl"
        rollout.parent.mkdir(parents=True)
        records = [
            {
                "type": "event_msg",
                "timestamp": "2026-07-18T08:00:00Z",
                "payload": {
                    "type": "token_count",
                    "info": {
                        "total_token_usage": {
                            "input_tokens": 10,
                            "cached_input_tokens": 5,
                            "output_tokens": 2,
                            "total_tokens": 12,
                        }
                    },
                },
            },
            {
                "type": "event_msg",
                "timestamp": "2026-07-18T08:01:00Z",
                "payload": {
                    "type": "token_count",
                    "info": {
                        "total_token_usage": {
                            "input_tokens": 100,
                            "cached_input_tokens": 50,
                            "output_tokens": 20,
                            "total_tokens": 120,
                        }
                    },
                },
            },
        ]
        rollout.write_text("".join(json.dumps(record) + "\n" for record in records))
        other = root / "sessions/2026/07/18/rollout-other.jsonl"
        other.write_text(json.dumps({
            "type": "session_meta",
            "payload": {"cwd": "/home/example/other-project"},
        }) + "\n" + json.dumps(records[-1]) + "\n")

        per, files, nested = MODULE.codex_token_side(root, "vauchi")

    assert files == 1
    assert nested == 0
    assert per["2026-07-18"]["msgs"] == 1
    assert per["2026-07-18"]["out"] == 20
    assert per["2026-07-18"]["eff"] == (100 - 50) + 20 * 5 + 50 * 0.1


if __name__ == "__main__":
    test_codex_token_side_uses_final_cumulative_usage()
    print("token-report-codex.test: PASS")
