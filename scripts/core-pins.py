#!/usr/bin/env python3
# SPDX-FileCopyrightText: 2026 Mattia Egloff <mattia.egloff@pm.me>
#
# SPDX-License-Identifier: GPL-3.0-or-later

"""Read, bump and check every consumer's native Core pin.

ADR-026 (amendment 2026-09-30, #434): each consumer pins Core in its own
ecosystem's manifest, and that pin is the only copy of the version. Core
lists its consumers in `ci/consumer-pins.json` (repo, pin kind, file,
which pipeline job bumps it). This tool is shared by Core's release
pipeline (`bump`), the consumers' CI templates (`read`), and the
workspace checkers (`check`).

Usage:
    core-pins.py read --kind KIND FILE
    core-pins.py bump --kind KIND --version X.Y.Z FILE
    core-pins.py consumers --table FILE [--bumped-by JOB]
    core-pins.py check --root DIR [--ref origin/main] [--table FILE] [--strict]
"""

from __future__ import annotations

import argparse
import json
import re
import subprocess
import sys
from pathlib import Path
from typing import Callable, NamedTuple, Optional

CORE_GIT_LINE = re.compile(r'git\s*=\s*"https://gitlab\.com/vauchi/core(?:\.git)?"')
CRATE_NAME = re.compile(r"^\s*([A-Za-z0-9_-]+)\s*=")
TAG = re.compile(r'tag\s*=\s*"([^"]+)"')
BRANCH = re.compile(r'branch\s*=\s*"[^"]*"')
EXACT_VERSION = re.compile(r'version\s*=\s*"=[^"]*"')
RELEASE_TAG = re.compile(r"^v(\d+)\.(\d+)\.(\d+)$")
HARDCODED_CI_REF = re.compile(r'^\s*(?:VAUCHI_)?CORE_REF:\s*"?v\d+\.\d+\.\d+')

# Kinds this tool rewrites. The others are bumped by the pipeline that
# publishes their artifact (update:swift-bindings, trigger:ios/macos/
# android/windows), because the pin carries data only that pipeline has
# (a signed checksum, a published binary).
BUMPABLE = {"cargo", "ref-file"}
FAILING = {"error", "behind", "hardcoded-ci-ref"}


class PinError(Exception):
    pass


def _tag(version: str) -> str:
    return version if version.startswith("v") else f"v{version}"


def _core_lines(text: str) -> list[tuple[int, str]]:
    return [(i, line) for i, line in enumerate(text.splitlines()) if CORE_GIT_LINE.search(line)]


def _read_cargo(text: str) -> str:
    lines = _core_lines(text)
    if not lines:
        raise PinError("no Core dependency in this manifest")
    tags = set()
    for _, line in lines:
        match = TAG.search(line)
        if not match:
            name = CRATE_NAME.match(line)
            raise PinError(f"{name.group(1) if name else 'a Core dependency'} is not pinned to a tag")
        tags.add(match.group(1))
    if len(tags) > 1:
        raise PinError(f"Core dependencies disagree: {', '.join(sorted(tags))}")
    return tags.pop()


def _read_ref_file(text: str) -> str:
    for line in text.splitlines():
        stripped = line.strip()
        if stripped and not stripped.startswith("#"):
            return stripped
    raise PinError("no Core ref in this file")


def _read_cabi_json(text: str) -> str:
    try:
        version = json.loads(text)["version"]
    except (ValueError, KeyError, TypeError) as err:
        raise PinError(f"no version in cabi-version.json ({err.__class__.__name__})") from err
    return _tag(version)


def _read_xcode_spm(text: str) -> str:
    block = re.search(
        r'repositoryURL = "https://gitlab\.com/vauchi/vauchi-platform-swift(?:\.git)?";'
        r"\s*requirement = \{[^}]*?version = ([0-9][^;]*);",
        text,
    )
    if not block:
        raise PinError("no vauchi-platform-swift package pin in the Xcode project")
    return _tag(block.group(1).strip())


def _read_gradle(text: str) -> str:
    versions = set(re.findall(r"app\.vauchi:vauchi-platform:([0-9][^\"']*)", text))
    if not versions:
        raise PinError("no app.vauchi:vauchi-platform dependency")
    if len(versions) > 1:
        raise PinError(f"vauchi-platform versions disagree: {', '.join(sorted(versions))}")
    return _tag(versions.pop())


def _read_swift_let_version(text: str) -> str:
    match = re.search(r'^let version = "([^"]+)"', text, re.MULTILINE)
    if not match:
        raise PinError("no `let version` in Package.swift")
    return _tag(match.group(1))


READERS: dict[str, Callable[[str], str]] = {
    "cargo": _read_cargo,
    "ref-file": _read_ref_file,
    "cabi-json": _read_cabi_json,
    "xcode-spm": _read_xcode_spm,
    "gradle": _read_gradle,
    "swift-let-version": _read_swift_let_version,
}


def read_pin(kind: str, text: str) -> str:
    reader = READERS.get(kind)
    if reader is None:
        raise PinError(f"unknown pin kind: {kind}")
    return reader(text)


def _bump_cargo(text: str, version: str) -> tuple[str, list[str]]:
    lines = text.splitlines(keepends=True)
    crates = []
    for i, _ in _core_lines(text):
        line = lines[i]
        name = CRATE_NAME.match(line)
        if name:
            crates.append(name.group(1))
        if TAG.search(line):
            line = TAG.sub(f'tag = "{_tag(version)}"', line, count=1)
        elif BRANCH.search(line):
            line = BRANCH.sub(f'tag = "{_tag(version)}"', line, count=1)
        else:
            raise PinError(f"{crates[-1] if crates else 'a Core dependency'} has no tag or branch to replace")
        lines[i] = EXACT_VERSION.sub(f'version = "={version.lstrip("v")}"', line, count=1)
    if not crates:
        raise PinError("no Core dependency in this manifest")
    return "".join(lines), crates


def _bump_ref_file(text: str, version: str) -> tuple[str, list[str]]:
    lines = text.splitlines(keepends=True)
    for i, line in enumerate(lines):
        stripped = line.strip()
        if stripped and not stripped.startswith("#"):
            lines[i] = _tag(version) + ("\n" if line.endswith("\n") else "")
            return "".join(lines), []
    raise PinError("no Core ref in this file")


def bump_pin(kind: str, text: str, version: str) -> tuple[str, list[str]]:
    """Return the rewritten file and, for Cargo, the crates to `cargo update -p`."""
    if kind not in READERS:
        raise PinError(f"unknown pin kind: {kind}")
    if kind not in BUMPABLE:
        raise PinError(f"a {kind} pin is bumped by its own pipeline, not by this tool")
    if kind == "cargo":
        return _bump_cargo(text, version)
    return _bump_ref_file(text, version)


def _release_key(tag: str) -> Optional[tuple[int, int, int]]:
    match = RELEASE_TAG.match(tag)
    return tuple(int(part) for part in match.groups()) if match else None  # type: ignore[return-value]


def latest_release_tag(tags: list[str]) -> str:
    releases = [tag for tag in tags if _release_key(tag)]
    if not releases:
        raise PinError("no release tag (vX.Y.Z) found")
    return max(releases, key=lambda tag: _release_key(tag))


def hardcoded_ci_refs(text: str) -> list[tuple[int, str]]:
    return [(n, line.strip()) for n, line in enumerate(text.splitlines(), 1) if HARDCODED_CI_REF.match(line)]


class Row(NamedTuple):
    repo: str
    bumped_by: str
    pin: str
    status: str
    note: str = ""


def check(table: dict, read_file: Callable[[str, str], Optional[str]], latest: str) -> list[Row]:
    rows = []
    for consumer in table["consumers"]:
        repo, kind, path = consumer["repo"], consumer["kind"], consumer["file"]
        bumped_by = consumer.get("bumped_by", "")
        text = read_file(repo, path)
        if text is None:
            rows.append(Row(repo, bumped_by, "-", "error", f"{path} not found"))
            continue
        try:
            pin = read_pin(kind, text)
        except PinError as err:
            rows.append(Row(repo, bumped_by, "-", "error", str(err)))
            continue
        hardcoded = hardcoded_ci_refs(read_file(repo, ".gitlab-ci.yml") or "")
        if hardcoded:
            note = "; ".join(f".gitlab-ci.yml line {n}: {line}" for n, line in hardcoded)
            rows.append(Row(repo, bumped_by, pin, "hardcoded-ci-ref", note))
            continue
        pin_key, latest_key = _release_key(pin), _release_key(latest)
        if pin_key is None:
            rows.append(Row(repo, bumped_by, pin, "error", "pin is not a release tag"))
        elif latest_key is not None and pin_key < latest_key:
            rows.append(Row(repo, bumped_by, pin, "behind", f"latest is {latest}"))
        else:
            rows.append(Row(repo, bumped_by, pin, "current"))
    return rows


def failed(rows: list[Row]) -> bool:
    return any(row.status in FAILING for row in rows)


def _git_show(root: Path, ref: str) -> Callable[[str, str], Optional[str]]:
    def read(repo: str, path: str) -> Optional[str]:
        repo_dir = root / repo
        if not (repo_dir / ".git").exists():
            return None
        result = subprocess.run(
            ["git", "-C", str(repo_dir), "show", f"{ref}:{path}"],
            capture_output=True, text=True, check=False,
        )
        return result.stdout if result.returncode == 0 else None

    return read


def _main(argv: list[str]) -> int:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = parser.add_subparsers(dest="command", required=True)

    read_cmd = sub.add_parser("read", help="print the Core ref a pin file names")
    read_cmd.add_argument("--kind", required=True)
    read_cmd.add_argument("file", type=Path)

    bump_cmd = sub.add_parser("bump", help="rewrite a pin file to a Core release")
    bump_cmd.add_argument("--kind", required=True)
    bump_cmd.add_argument("--version", required=True)
    bump_cmd.add_argument("file", type=Path)

    list_cmd = sub.add_parser("consumers", help="list consumers from the table")
    list_cmd.add_argument("--table", required=True, type=Path)
    list_cmd.add_argument("--bumped-by")

    check_cmd = sub.add_parser("check", help="compare every consumer's pin with the latest Core release")
    check_cmd.add_argument("--root", required=True, type=Path)
    check_cmd.add_argument("--ref", default="origin/main")
    check_cmd.add_argument("--table", type=Path)
    check_cmd.add_argument("--strict", action="store_true")

    args = parser.parse_args(argv)
    try:
        if args.command == "read":
            print(read_pin(args.kind, args.file.read_text(encoding="utf-8")))
        elif args.command == "bump":
            text, crates = bump_pin(args.kind, args.file.read_text(encoding="utf-8"), args.version)
            args.file.write_text(text, encoding="utf-8")
            for crate in crates:
                print(crate)
        elif args.command == "consumers":
            table = json.loads(args.table.read_text(encoding="utf-8"))
            for consumer in table["consumers"]:
                if args.bumped_by is None or consumer.get("bumped_by") == args.bumped_by:
                    print(consumer["repo"], consumer["kind"], consumer["file"])
        else:
            read = _git_show(args.root, args.ref)
            table_text = args.table.read_text(encoding="utf-8") if args.table else read("core", "ci/consumer-pins.json")
            if table_text is None:
                raise PinError(f"core {args.ref}:ci/consumer-pins.json not found")
            tags = subprocess.run(
                ["git", "-C", str(args.root / "core"), "tag", "-l", "v*"],
                capture_output=True, text=True, check=True,
            ).stdout.split()
            latest = latest_release_tag(tags)
            rows = check(json.loads(table_text), read, latest)
            print(f"Latest Core release: {latest} (pins read from {args.ref})")
            for row in rows:
                print(f"  {row.repo:<22} {row.pin:<10} {row.status:<17} {row.bumped_by:<22} {row.note}".rstrip())
            if args.strict and failed(rows):
                return 1
    except PinError as err:
        print(f"core-pins: {err}", file=sys.stderr)
        return 2
    except OSError as err:
        print(f"core-pins: {err.filename}: {err.strerror}", file=sys.stderr)
        return 2
    return 0


if __name__ == "__main__":
    sys.exit(_main(sys.argv[1:]))
