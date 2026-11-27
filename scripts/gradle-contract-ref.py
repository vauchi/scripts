#!/usr/bin/env python3
# SPDX-FileCopyrightText: 2026 Mattia Egloff <mattia.egloff@pm.me>
# SPDX-License-Identifier: GPL-3.0-or-later
"""Print the contract release tag selected by a strict Gradle lockfile."""

import argparse
from pathlib import Path
import re
import sys

MAX_LOCK_BYTES = 1024 * 1024
CONTRACT_ROW = re.compile(r"app\.vauchi:contract(?::|=|$)")
LOCKED_RELEASE = re.compile(
    r"app\.vauchi:contract:((?:0|[1-9][0-9]*)\.(?:0|[1-9][0-9]*)\."
    r"(?:0|[1-9][0-9]*))=([^\s,=]+(?:,[^\s,=]+)*)"
)


def contract_ref(lock: Path) -> str:
    if lock.is_symlink() or not lock.is_file():
        raise ValueError("contract lock must be a regular source file")
    with lock.open("rb") as source:
        data = source.read(MAX_LOCK_BYTES + 1)
    if len(data) > MAX_LOCK_BYTES:
        raise ValueError("contract lock exceeds the 1 MiB input limit")
    rows = [
        line.strip() for line in data.decode("utf-8").splitlines()
        if CONTRACT_ROW.match(line.strip())
    ]
    if len(rows) != 1:
        raise ValueError("contract lock must name exactly one contract release")
    match = LOCKED_RELEASE.fullmatch(rows[0])
    if match is None:
        raise ValueError("contract lock requires an exact release and nonempty configurations")
    configurations = match[2].split(",")
    if len(configurations) != len(set(configurations)):
        raise ValueError("contract lock repeats a configuration")
    return f"v{match[1]}"


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("lockfile", type=Path)
    args = parser.parse_args()
    try:
        tag = contract_ref(args.lockfile)
    except (OSError, ValueError) as error:
        print(f"ERROR: {error}", file=sys.stderr)
        return 2
    print(tag)
    return 0


if __name__ == "__main__":
    sys.exit(main())
