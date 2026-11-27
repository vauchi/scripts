#!/usr/bin/env python3
# SPDX-FileCopyrightText: 2026 Mattia Egloff <mattia.egloff@pm.me>
#
# SPDX-License-Identifier: GPL-3.0-or-later

"""Check ADR-078 composition-root and contract dependency boundaries."""

import argparse
import json
import sys
import tomllib
from pathlib import Path

CORE_CRATES = {"vauchi-core", "vauchi-app", "vauchi-platform", "vauchi-cabi"}
DISPLAY_CRATES = {"gtk-display", "qt-display", "cli-display", "tui-display"}
CLI_EXCEPTION = "cli-display/Cargo.toml"
REQUIRED_CARGO_SHELLS = (
    "gtk-display/Cargo.toml",
    "linux-hw/Cargo.toml",
    "cli-display/cli-display/Cargo.toml",
    "tui-display/Cargo.toml",
)
REQUIRED_APP_DEPENDENCIES = {"vauchi-core", "vauchi-app", "vauchi-contract", "vauchi-linux-hw"}
SOURCE_SUFFIXES = {".cpp", ".h", ".hpp"}


class CompositionChecker:
    def __init__(self, root: Path, baseline_path: Path):
        self.root = root
        self.baseline_path = baseline_path
        self.errors = []
        self.exceptions = set()

    def require(self, condition: bool, message: str) -> None:
        if not condition:
            self.errors.append(message)

    def load_baseline(self) -> None:
        try:
            document = json.loads(self.baseline_path.read_text(encoding="utf-8"))
        except (OSError, json.JSONDecodeError) as error:
            self.errors.append(f"invalid or missing baseline {self.baseline_path}: {error}")
            return
        if document.get("schema_version") != 1 or not isinstance(document.get("exceptions"), list):
            self.errors.append("invalid baseline: schema_version 1 and an exceptions list are required")
            return
        for exception in document["exceptions"]:
            path = exception.get("path") if isinstance(exception, dict) else None
            issue = exception.get("issue") if isinstance(exception, dict) else None
            if path != CLI_EXCEPTION or issue != "vauchi/private#1233":
                self.errors.append(f"unexpected exception in baseline: {path or issue or exception}")
            else:
                self.exceptions.add(path)

    def dependency_names(self, manifest: Path) -> set[str]:
        try:
            document = tomllib.loads(manifest.read_text(encoding="utf-8"))
        except (OSError, tomllib.TOMLDecodeError) as error:
            self.errors.append(f"cannot read manifest {manifest}: {error}")
            return set()

        names = set()

        def collect(node) -> None:
            if isinstance(node, dict):
                for key, value in node.items():
                    if key in CORE_CRATES or key in DISPLAY_CRATES or key in {
                        "vauchi-contract",
                        "vauchi-linux-hw",
                    }:
                        names.add(key)
                    collect(value)
            elif isinstance(node, list):
                for item in node:
                    collect(item)

        collect(document)
        return names

    def check_cargo_shell(self, relative: str) -> None:
        path = self.root / relative
        self.require(path.is_file(), f"missing required manifest {relative}")
        if not path.is_file():
            return
        names = self.dependency_names(path)
        forbidden = sorted(names & CORE_CRATES)
        if relative in self.exceptions:
            return
        self.require(not forbidden, f"{relative} links Core implementation crates: {', '.join(forbidden)}")
        if relative != CLI_EXCEPTION:
            self.require(
                "vauchi-contract" in names,
                f"{relative} does not declare vauchi-contract",
            )

    def check_qt_display(self) -> None:
        cmake = self.root / "qt-display/CMakeLists.txt"
        self.require(cmake.is_file(), "missing required manifest qt-display/CMakeLists.txt")
        self.require(
            (self.root / "qt-display/contract-ref").is_file(),
            "missing required contract pin qt-display/contract-ref",
        )
        if cmake.is_file():
            for line in cmake.read_text(encoding="utf-8").splitlines():
                stripped = line.strip()
                if not stripped.startswith(("find_package", "target_link_libraries")):
                    continue
                for crate in CORE_CRATES:
                    self.require(
                        crate not in stripped,
                        f"qt-display/CMakeLists.txt links Core implementation crate {crate}",
                    )
        source_root = self.root / "qt-display/src"
        if not source_root.is_dir():
            self.errors.append("missing required production source directory qt-display/src")
            return
        for source in source_root.rglob("*"):
            if source.suffix in SOURCE_SUFFIXES and source.is_file() and "core-ref" in source.read_text(encoding="utf-8"):
                self.errors.append(f"qt-display/core-ref used by production source {source.relative_to(self.root)}")

    def check_linux_app(self) -> None:
        names = self.dependency_names(self.root / "linux-app/Cargo.toml")
        self.require(
            REQUIRED_APP_DEPENDENCIES <= names,
            "linux-app/Cargo.toml is missing required dependencies: "
            + ", ".join(sorted(REQUIRED_APP_DEPENDENCIES - names)),
        )
        self.require(
            bool(names & DISPLAY_CRATES),
            "linux-app/Cargo.toml declares no display shell",
        )

    def run(self) -> int:
        self.require(self.root.is_dir(), f"workspace root does not exist: {self.root}")
        self.require(self.baseline_path.is_file(), f"missing baseline {self.baseline_path}")
        if self.errors:
            return self.report()
        self.load_baseline()
        if self.errors:
            return self.report()
        for relative in REQUIRED_CARGO_SHELLS:
            self.check_cargo_shell(relative)
        self.check_cargo_shell(CLI_EXCEPTION)
        self.check_qt_display()
        self.check_linux_app()
        return self.report()

    def report(self) -> int:
        if self.errors:
            for error in self.errors:
                print(f"composition-architecture: {error}", file=sys.stderr)
            return 1
        print("composition-architecture: contract-only shells and one app composition root verified")
        return 0


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--root", type=Path, default=Path("."))
    parser.add_argument("--baseline", type=Path, required=True)
    args = parser.parse_args()
    return CompositionChecker(args.root, args.baseline).run()


if __name__ == "__main__":
    sys.exit(main())
