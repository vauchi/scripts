#!/usr/bin/env python3
# SPDX-FileCopyrightText: 2026 Mattia Egloff <mattia.egloff@pm.me>
#
# SPDX-License-Identifier: GPL-3.0-or-later

"""Read the central repository registry (repos.toml) and answer queries.

The workspace root is found by walking up from this script's location looking
for repos.toml. Queries return newline or space separated values suitable for
shell capture and just variable expansion.

Usage:
    repo-registry.py public           # space-separated public repo names
    repo-registry.py private          # private repo name (or empty)
    repo-registry.py tooling          # space-separated tooling repo names
    repo-registry.py all              # space-separated all repo names
    repo-registry.py mobile           # space-separated mobile repo names
    repo-registry.py has-ci           # space-separated repos with CI
    repo-registry.py publish          # space-separated repos that publish artifacts
    repo-registry.py dir <repo>       # directory path for repo
    repo-registry.py toolchain <repo> # ecosystem for repo
"""

from __future__ import annotations

import os
import sys
from pathlib import Path
from typing import Any

try:
    import tomllib  # type: ignore[import-not-found]
except ModuleNotFoundError:  # pragma: no cover
    import tomli as tomllib  # type: ignore[import-not-found, no-redef]


def _find_repos_toml() -> Path:
    """Locate repos.toml relative to the workspace root.

    The registry lives at the workspace root if checked out normally, or at
    <workspace-root>/root/repos.toml when the root repo is a sibling of the
    scripts repo (the standard Vauchi worktree layout).
    """
    d = Path.cwd().resolve()
    candidates = [d / "repos.toml", d / "root" / "repos.toml"]
    for candidate in candidates:
        if candidate.is_file():
            return candidate

    # Fallback: walk up from the script location, checking both layouts.
    d = Path(__file__).resolve().parent
    while True:
        for candidate in (d / "repos.toml", d / "root" / "repos.toml"):
            if candidate.is_file():
                return candidate
        parent = d.parent
        if parent == d:
            break
        d = parent
    raise FileNotFoundError("repos.toml not found in workspace")


def _load_registry() -> dict[str, Any]:
    path = _find_repos_toml()
    with open(path, "rb") as fh:
        return tomllib.load(fh)


def _repos() -> list[dict[str, Any]]:
    data = _load_registry()
    return data.get("repo", [])


def _names(where: dict[str, Any] | None = None) -> list[str]:
    repos = _repos()
    if where is None:
        return [r["name"] for r in repos]
    return [r["name"] for r in repos if all(r.get(k) == v for k, v in where.items())]


def _get(name: str) -> dict[str, Any] | None:
    for repo in _repos():
        if repo.get("name") == name:
            return repo
    return None


_COMMANDS: dict[str, list[str]] = {
    "public": ["public=true"],
    "private": ["private=true"],
    "mobile": ["mobile=true"],
    "has-ci": ["has_ci=true"],
    "publish": ["publish_artifact=true"],
    "all": [],
}


def _parse_flag_query(query: str) -> dict[str, Any]:
    """Convert 'key=value' or bare 'key' (truthy) into a filter dict."""
    result: dict[str, Any] = {}
    for part in query.split():
        if "=" in part:
            k, v = part.split("=", 1)
            result[k] = v == "true" if v in ("true", "false") else v
        else:
            result[part] = True
    return result


def main(argv: list[str]) -> int:
    if not argv:
        print("ERROR: missing command", file=sys.stderr)
        return 2

    cmd = argv[0]

    if cmd == "dir":
        if len(argv) != 2:
            print("ERROR: dir requires a repo name", file=sys.stderr)
            return 2
        repo = _get(argv[1])
        if repo is None:
            print(f"ERROR: unknown repo '{argv[1]}'", file=sys.stderr)
            return 1
        print(repo.get("path", ""))
        return 0

    if cmd == "toolchain":
        if len(argv) != 2:
            print("ERROR: toolchain requires a repo name", file=sys.stderr)
            return 2
        repo = _get(argv[1])
        if repo is None:
            print(f"ERROR: unknown repo '{argv[1]}'", file=sys.stderr)
            return 1
        print(repo.get("ecosystem", ""))
        return 0

    if cmd == "tooling":
        print(" ".join(r["name"] for r in _repos() if r.get("clone_url")))
        return 0

    if cmd == "list":
        for r in _repos():
            print(f"{r['name']}:{r.get('path', '')}:{r.get('ecosystem', 'none')}")
        return 0

    if cmd == "query":
        if len(argv) != 2:
            print("ERROR: query requires a filter expression", file=sys.stderr)
            return 2
        print(" ".join(_names(_parse_flag_query(argv[1]))))
        return 0

    if cmd in _COMMANDS:
        query = _COMMANDS[cmd]
        if query:
            print(" ".join(_names(_parse_flag_query(" ".join(query)))))
        else:
            print(" ".join(_names()))
        return 0

    print(f"ERROR: unknown command '{cmd}'", file=sys.stderr)
    return 2


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
