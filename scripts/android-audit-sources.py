#!/usr/bin/env python3
# SPDX-FileCopyrightText: 2026 Mattia Egloff <mattia.egloff@pm.me>
# SPDX-License-Identifier: GPL-3.0-or-later

"""Emit NUL-delimited production Kotlin paths for Android source audits."""

import argparse
import os
from pathlib import Path
import re
import sys


def fail_walk(error):
    raise error


def sources(root, required=False, omit=None):
    if root.is_symlink() or not root.is_dir():
        if required:
            raise ValueError(f"no regular production source root: {root}")
        return []
    result = []
    for directory, children, files in os.walk(root, onerror=fail_walk):
        parent = Path(directory)
        for name in children[:]:
            child = parent / name
            if child == omit:
                children.remove(name)
            elif child.is_symlink():
                if required:
                    raise ValueError(f"linked source directory: {child}")
                children.remove(name)
        for name in sorted(files):
            path = parent / name
            if path.is_symlink():
                if required:
                    raise ValueError(f"linked source file: {path}")
                continue
            if path.suffix != ".kt" or any(
                part in path.as_posix() for part in ("/src/test/", "/src/androidTest/")
            ):
                continue
            if not path.is_file():
                raise ValueError(f"nonregular source file: {path}")
            path.read_text(encoding="utf-8")
            result.append(path)
    if required and not result:
        raise ValueError(f"no Kotlin production sources: {root}")
    return result


def module_sources(module):
    for root in (module, module / "src", module / "src/main"):
        if root.is_symlink() or not root.is_dir():
            raise ValueError(f"no regular production source root: {root}")
    return sources(module / "src/main", required=True)


def select_sources(workspace):
    app = next((candidate for candidate in (workspace / "android-app", workspace / "android")
                if candidate.is_dir()), None)
    if app is None and (workspace / "app").is_dir():
        app = workspace
    settings = (app or workspace) / "settings.gradle.kts"
    settings_text = settings.read_text(encoding="utf-8") if settings.exists() else ""
    settings_text = re.sub(r"//[^\n]*", "", settings_text)
    standalone = workspace.name == "android-display" or re.search(
        r'^\s*rootProject\.name\s*=\s*"android-display"\s*$', settings_text, re.MULTILINE
    )
    independent = None
    if "VAUCHI_ANDROID_DISPLAY_ROOT" in os.environ:
        declared = os.environ["VAUCHI_ANDROID_DISPLAY_ROOT"]
        if not declared:
            raise ValueError("empty required display source checkout")
        independent = Path(declared).absolute()
    elif (workspace / "android-display").exists() or (workspace / "android-display").is_symlink():
        independent = workspace / "android-display"
    elif standalone:
        independent = workspace
    selected = module_sources(independent) if independent is not None else []
    if app is not None:
        in_place = app / "display"
        declared_in_place = '":display"' in settings_text
        if declared_in_place:
            module_sources(in_place)
        selected += sources(app, omit=in_place if independent is not None and not declared_in_place else None)
    return sorted(set(selected))


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("workspace", type=Path)
    args = parser.parse_args()
    try:
        for path in select_sources(args.workspace.absolute()):
            sys.stdout.buffer.write(os.fsencode(path) + b"\0")
    except (OSError, UnicodeError, ValueError) as error:
        print(f"Android audit source error: {error}", file=sys.stderr)
        return 2
    return 0


if __name__ == "__main__":
    sys.exit(main())
