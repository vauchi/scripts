#!/usr/bin/env python3
"""Validate the shared Event -> Core -> Command[] boundary fixture."""
import json
import sys
from pathlib import Path

REQUIRED_COMMAND_FIELDS = {
    "kind", "id", "text", "accessibility", "enabled", "selected", "tokens"
}


def fail(message: str) -> int:
    print(f"boundary-contract: {message}", file=sys.stderr)
    return 1


def main() -> int:
    if len(sys.argv) != 2:
        print("usage: check-boundary-contract.py FIXTURE.json", file=sys.stderr)
        return 2
    try:
        document = json.loads(Path(sys.argv[1]).read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError) as exc:
        return fail(f"cannot read fixture: {exc}")
    if document.get("schema") != "event-core-command-v1":
        return fail("schema must be event-core-command-v1")
    event = document.get("event")
    if not isinstance(event, dict) or not isinstance(event.get("kind"), str):
        return fail("event must contain a string kind")
    commands = document.get("commands")
    if not isinstance(commands, list):
        return fail("commands must be an array")
    for index, command in enumerate(commands):
        if not isinstance(command, dict):
            return fail(f"commands[{index}] must be an object")
        missing = REQUIRED_COMMAND_FIELDS - command.keys()
        if missing:
            return fail(f"commands[{index}] missing: {', '.join(sorted(missing))}")
        if not isinstance(command["id"], str) or not command["id"]:
            return fail(f"commands[{index}].id must be opaque text")
        if not isinstance(command["accessibility"], dict):
            return fail(f"commands[{index}].accessibility must be an object")
        if not isinstance(command["tokens"], dict):
            return fail(f"commands[{index}].tokens must be an object")
        if not isinstance(command["enabled"], bool) or not isinstance(command["selected"], bool):
            return fail(f"commands[{index}] enabled/selected must be boolean")
    print(f"boundary-contract: OK ({len(commands)} command(s))")
    return 0


if __name__ == "__main__":
    sys.exit(main())
