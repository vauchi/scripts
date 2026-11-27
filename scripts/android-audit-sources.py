#!/usr/bin/env python3
# SPDX-FileCopyrightText: 2026 Mattia Egloff <mattia.egloff@pm.me>
# SPDX-License-Identifier: GPL-3.0-or-later

"""Emit NUL-delimited source files or roots for Android source audits."""

import argparse
import os
from pathlib import Path
import re
import sys

EXCLUSIONS = {
    "text": (),
    "loc": ("/Generated/", "/generated/", "/Bindings/", "/Libs/", "/.build/", "/Tests/", "/node_modules/", "/dist/"),
    "vocab": ("/Generated/", "/uniffi/", "/Libs/", "/build/", "/locales/", "/test/", "/androidTest/", "/Tests/", "Tests.swift", "Test.kt"),
}


def fail_walk(error):
    raise error


def sources(root, required=False, omit=None, exclusions=()):
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
                part in path.as_posix() for part in ("/src/test/", "/src/androidTest/", *exclusions)
            ):
                continue
            if not path.is_file():
                raise ValueError(f"nonregular source file: {path}")
            path.read_text(encoding="utf-8")
            result.append(path)
    if required and not result:
        raise ValueError(f"no Kotlin production sources: {root}")
    return result


def module_sources(module, exclusions):
    for root in (module, module / "src", module / "src/main"):
        if root.is_symlink() or not root.is_dir():
            raise ValueError(f"no regular production source root: {root}")
    return sources(module / "src/main", required=True, exclusions=exclusions)


def select_sources(workspace, app_scope, exclusions):
    if not workspace.is_dir():
        raise ValueError(f"workspace is not a directory: {workspace}")
    app = next((candidate for candidate in (workspace / "android-app", workspace / "android")
                if candidate.is_dir()), None)
    if app is None and (workspace / "app").is_dir():
        app = workspace
    settings = (app or workspace) / "settings.gradle.kts"
    settings_text = settings.read_text(encoding="utf-8") if settings.exists() else ""
    settings_text = re.sub(r"//[^\n]*", "", settings_text)
    if app is None and '":display"' in settings_text:
        app = workspace
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
    selected = module_sources(independent, exclusions) if independent is not None else []
    roots = [independent / "src/main"] if independent is not None else []
    if app is not None:
        in_place = app / "display"
        declared_in_place = '":display"' in settings_text
        if declared_in_place:
            module_sources(in_place, exclusions)
        if app_scope == "whole":
            selected += sources(app, omit=in_place if independent is not None and not declared_in_place else None, exclusions=exclusions)
        else:
            app_source = app / "app/src/main"
            selected += sources(app_source, exclusions=exclusions)
            if app_source.is_dir() and not app_source.is_symlink():
                roots.append(app_source)
            if independent is None or declared_in_place:
                module_root = in_place / "src/main"
                if all(path.is_dir() and not path.is_symlink()
                       for path in (in_place, in_place / "src", module_root)):
                    selected += sources(module_root, exclusions=exclusions)
                    roots.append(module_root)
    return sorted(set(selected)), sorted(set(roots))


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("workspace", type=Path)
    parser.add_argument("--app-scope", choices=("whole", "main"), default="whole")
    parser.add_argument("--policy", choices=EXCLUSIONS, default="text")
    parser.add_argument("--roots", action="store_true")
    args = parser.parse_args()
    if args.roots and args.app_scope != "main":
        parser.error("--roots requires --app-scope main")
    try:
        files, roots = select_sources(args.workspace.absolute(), args.app_scope, EXCLUSIONS[args.policy])
        for path in roots if args.roots else files:
            sys.stdout.buffer.write(os.fsencode(path) + b"\0")
    except (OSError, UnicodeError, ValueError) as error:
        print(f"Android audit source error: {error}", file=sys.stderr)
        return 2
    return 0


if __name__ == "__main__":
    sys.exit(main())
