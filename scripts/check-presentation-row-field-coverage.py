#!/usr/bin/env python3
# SPDX-FileCopyrightText: 2026 Mattia Egloff <mattia.egloff@pm.me>
# SPDX-License-Identifier: GPL-3.0-or-later
"""Check that every `PresentationRow` field Core populates is rendered by
every shell that renders rows.

Source of truth:
`contract/src/presentation/surface/nodes.rs` — the canonical
`PresentationRow` struct, with pre-migration Core fallback. Fields are extracted and each
shell's row renderer is searched for a read of that field.

Why this exists, and why variant parity is not enough:
`check-component-parser-parity.py` already guards `PresentationNode`
*variants*, which is why all thirteen render everywhere. Nothing guarded
the *fields* of a row, and four defects lived in that gap — each one Core
populating a field that a shell decoded and then silently discarded:

  - `controls` dropped by iOS, so six privacy settings rendered as text
    with no switch and could not be changed at all.
  - `image_data` / `fallback_text` dropped by Android, so contact rows
    were bare text where iOS drew the initials circle.
  - `icon_token` dropped by every shell, so Core prepares icons for nav
    items, card fields and list rows that nobody draws.

Note the shape of the first one: Android rendered `controls` correctly
while iOS did not. A check that asked "does *any* shell read this field"
would have passed while the settings were dead, so this checks every
row-rendering shell separately.

Exemptions live in `check-presentation-row-field-coverage.exemptions.json`
and each carries a reason. They are visible debt, not silence: a field
exempted everywhere is a field Core prepares for nobody.

Exit codes:
  0  coverage OK
  1  a field is unread by a shell and unexempted
  2  bad invocation / missing files

Usage:
  python3 scripts/check-presentation-row-field-coverage.py
  python3 scripts/check-presentation-row-field-coverage.py --workspace /path
"""

import argparse
import os
import json
import re
import sys
from pathlib import Path

ROW_STRUCT_FILE = "contract/src/presentation/surface/nodes.rs"
LEGACY_ROW_STRUCT_FILE = "core/vauchi-core/src/platform/presentation/surface/nodes.rs"
STRUCT_NAME = "PresentationRow"
EXEMPTIONS_FILE = "check-presentation-row-field-coverage.exemptions.json"
SOURCE_EXTENSIONS = {".rs", ".cpp", ".cc", ".cxx", ".h", ".hpp", ".cs", ".kt", ".java", ".swift", ".tsx", ".ts", ".jsx", ".js", ".qml", ".xaml"}


def snake_to_camel(name: str) -> str:
    head, *tail = name.split("_")
    return head + "".join(part.capitalize() for part in tail)


def snake_to_pascal(name: str) -> str:
    return "".join(part.capitalize() for part in name.split("_"))


# Each shell that renders rows: (paths, name transform).
# Paths may be a file or a directory; directories are searched recursively.
#
# A field counts as rendered if EITHER its wire name (`fallback_text`) or
# its shell-cased name (`fallbackText`) appears. Shells differ in which
# they touch — Windows and linux-qt read JSON keys by wire name while iOS
# and Android read decoded properties — and pinning one spelling per shell
# produced false failures rather than findings.
SHELLS = {
    "ios": (["ios/Vauchi/CoreUI/PresentationNodeView.swift"], snake_to_camel),
    "macos": (["macos/Vauchi/CoreUI/PresentationNodeView.swift"], snake_to_camel),
    "android": (
        ["android/app/src/main/kotlin/app/vauchi/ui/presentation/PresentationNodeRenderer.kt"],
        snake_to_camel,
    ),
    # Two paths: the TUI splits row handling between the renderer and the
    # protocol module, which owns `row_is_addressable`/`row_toggle` so the
    # highlight and the keypress cannot disagree. Scoping to the renderer
    # alone reported `activation` as dropped the moment that moved.
    "tui": (
        ["tui/src/ui/presentation_renderer", "tui/src/ui/presentation_protocol.rs"],
        lambda n: n,
    ),
    "linux-gtk": (["linux-gtk/src/core_ui/generic_surface"], lambda n: n),
    "linux-qt": (["linux-qt/src/coreui"], snake_to_camel),
    "windows": (["windows-display/src/Vauchi.Display"], snake_to_pascal),
    "web-demo": (["web-demo/src/presentation"], snake_to_camel),
}


def extract_fields(path: Path) -> list[str]:
    """Field names of the `PresentationRow` struct, in declaration order."""
    text = path.read_text(encoding="utf-8")
    match = re.search(
        rf"pub struct {STRUCT_NAME} \{{(.*?)\n\}}", text, re.S
    )
    if not match:
        raise ValueError(f"`{STRUCT_NAME}` not found in {path}")
    fields = re.findall(r"^\s*pub (\w+):", match.group(1), re.M)
    if not fields:
        raise ValueError(f"no PresentationRow fields found in {path}")
    return fields


# ADR-078 renamed linux-gtk and linux-qt (private#1029). The tables keep
# the shell names; a workspace that already has the new directory is read
# there. Looking under one name only would skip the shell and pass.
RENAMED_DIRS = {
    "linux-gtk": "gtk-display",
    "linux-qt": "qt-display",
    "windows": "windows-app",
    "tui": "tui-display",
}


def independent_android_source(root: Path, rel: str) -> Path | None:
    explicit = os.environ.get("VAUCHI_ANDROID_DISPLAY_ROOT")
    module = None
    if explicit is not None:
        if not explicit:
            raise ValueError("VAUCHI_ANDROID_DISPLAY_ROOT must name a display checkout")
        module = Path(explicit)
    elif (root / "android-display").exists() or (root / "android-display").is_symlink():
        module = root / "android-display"
    else:
        settings = root / "settings.gradle.kts"
        if settings.is_file() and re.search(
            r'^\s*rootProject[.]name\s*=\s*"android-display"\s*(?://.*)?$',
            settings.read_text(encoding="utf-8"), re.M,
        ):
            module = root
    if module is None:
        return None
    target = module / rel.removeprefix("android/app/")
    for candidate in (target, *target.parents):
        if candidate.is_symlink():
            raise OSError(f"required Android display source uses a link: {candidate}")
        if candidate == module:
            break
    if not target.is_file():
        raise FileNotFoundError(f"required Android display source is missing: {target}")
    return target


def in_workspace(root: Path, rel: str) -> Path:
    if rel.startswith("android/app/src/main/kotlin/app/vauchi/ui/presentation/"):
        independent = independent_android_source(root, rel)
        if independent is not None:
            return independent
        library = root / "android/display"
        settings = root / "android/settings.gradle.kts"
        text = re.sub(r"//.*$", "", settings.read_text(encoding="utf-8"), flags=re.M) if settings.is_file() else ""
        if library.is_dir() or '":display"' in text or "':display'" in text:
            return library / rel.removeprefix("android/app/")
    head, _, tail = rel.partition("/")
    renamed = RENAMED_DIRS.get(head)
    if renamed and (root / renamed).is_dir():
        return root / renamed / tail if tail else root / renamed
    return root / rel


def sources(root: Path, paths: list[str]) -> list[Path]:
    found: list[Path] = []
    for entry in paths:
        target = in_workspace(root, entry)
        if target.is_dir():
            found.extend(
                p for p in target.rglob("*") if p.is_file() and p.suffix in SOURCE_EXTENSIONS
            )
        elif target.is_file():
            found.append(target)
    return found


def reads_field(files: list[Path], names: list[str]) -> bool:
    """Whether any file actually reads the field off a row.

    Deliberately not a bare word match. `subtitle` alone also matches the
    local binding in `if let subtitle = row.subtitle`, so deleting the read
    left the word behind and the check could not fail — a sentinel run
    caught that before this shipped. A read is a member access (`.subtitle`,
    `.Subtitle`) or a wire key (`"subtitle"`); nothing else counts.
    """
    alternatives = []
    for name in names:
        escaped = re.escape(name)
        alternatives.append(rf"\.{escaped}\b")
        alternatives.append(rf'"{escaped}"')
    pattern = re.compile("|".join(alternatives))
    texts = [p.read_text(encoding="utf-8") for p in files]
    return any(pattern.search(text) for text in texts)


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--workspace", default=".", help="workspace root")
    parser.add_argument("--frontend", choices=sorted(SHELLS), help="Check only one row-rendering frontend.")
    parser.add_argument("--struct-file", type=Path, help="Canonical PresentationRow schema (overrides workspace lookup).")
    parser.add_argument(
        "--exemptions",
        help="exemptions JSON (defaults to the file beside this script); "
        "overridable so the self-test can exercise the gate without the "
        "real baseline deciding the outcome",
    )
    args = parser.parse_args()
    root = Path(args.workspace).absolute()

    struct_path = args.struct_file
    if struct_path is None:
        contract_lib = root / "contract/src/lib.rs"
        lib_text = contract_lib.read_text(encoding="utf-8") if contract_lib.is_file() else ""
        contract_declared = (root / "contract/src/presentation").is_dir() or re.search(
            r"(?m)^\s*(?:pub(?:\([^)]*\))?\s+)?mod\s+presentation\s*;", lib_text
        )
        struct_path = root / (ROW_STRUCT_FILE if contract_declared else LEGACY_ROW_STRUCT_FILE)
    if not struct_path.is_file():
        print(f"error: source of truth not found: {struct_path}", file=sys.stderr)
        return 2

    exemptions_path = (
        Path(args.exemptions) if args.exemptions else Path(__file__).with_name(EXEMPTIONS_FILE)
    )
    exemptions = json.loads(exemptions_path.read_text(encoding="utf-8")) if exemptions_path.is_file() else {}

    fields = extract_fields(struct_path)
    selected_shells = {args.frontend: SHELLS[args.frontend]} if args.frontend else SHELLS
    print(f"── {STRUCT_NAME} field coverage ──")
    print(f"  {len(fields)} fields, {len(selected_shells)} row-rendering shells")

    failures: list[str] = []
    missing_shells: list[str] = []

    for shell, (paths, transform) in sorted(selected_shells.items()):
        files = sources(root, paths)
        if not files:
            missing_shells.append(f"{shell}: none of {paths} exist")
            continue
        exempt = exemptions.get(shell, {})
        unread = [f for f in fields if not reads_field(files, [f, transform(f)])]
        unexempted = [f for f in unread if f not in exempt]
        exempted = [f for f in unread if f in exempt]
        status = "OK" if not unexempted else "MISSING"
        note = f" ({len(exempted)} exempt)" if exempted else ""
        print(f"  {shell:<10} {status}{note}")
        for field in unexempted:
            failures.append(
                f"{shell} never reads `{field}` "
                f"(looked for `{field}` or `{transform(field)}` in {', '.join(map(str, files))})"
            )

    if missing_shells:
        print("\nerror: a shell's row renderer could not be located —", file=sys.stderr)
        print("update SHELLS rather than dropping the shell silently:", file=sys.stderr)
        for line in missing_shells:
            print(f"  {line}", file=sys.stderr)
        return 2

    if failures:
        print("\nFAILED: Core populates a row field a shell never renders.", file=sys.stderr)
        for line in failures:
            print(f"  {line}", file=sys.stderr)
        print(
            "\nRender it, or add it to "
            f"scripts/{EXEMPTIONS_FILE} with a reason.",
            file=sys.stderr,
        )
        return 1

    print("  Row field coverage OK")
    return 0


if __name__ == "__main__":
    try:
        sys.exit(main())
    except (OSError, UnicodeError, ValueError) as error:
        print(f"error: incomplete audit input: {error}", file=sys.stderr)
        sys.exit(2)
