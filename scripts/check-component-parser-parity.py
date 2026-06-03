#!/usr/bin/env python3
# SPDX-FileCopyrightText: 2026 Mattia Egloff <mattia.egloff@pm.me>
# SPDX-License-Identifier: GPL-3.0-or-later
"""Check that every frontend's ScreenModel parser handles every Component
variant that core's canonical enum declares.

Source of truth: `core/vauchi-app/src/ui/component/mod.rs` — the
`Component` enum (split out of the former single-file `component.rs` by
Wire Humble Tier 0 in core 0.41.0). This script extracts variant names
from that file and verifies each frontend's hand-rolled parser file
mentions every variant. The pre-Tier-0 single-file layout
(`component.rs`) is still recognised when --enum-file is omitted, so
older binding refs continue to work.

Why: each frontend deserializes the externally-tagged
`{"VariantName": {...}}` JSON shape (or, for Swift, decodes it into a
hand-rolled `enum Component: Decodable`) with its own dispatch table.
Drift is silent — a new core variant rendered as a warning placeholder
(or, on Swift, simply un-decodable) ships without anyone noticing.

Naming conventions differ per frontend, so each entry carries a
`transform` that maps the canonical PascalCase variant onto the form
that frontend uses (e.g. Swift lower-camelCases its enum cases:
`Component::Row` → `case row(RowComponent)`).

Out of scope:
  - iOS / macOS native view code — they consume the **shared**
    `vauchi-platform-swift/Sources/CoreUIModels/Models.swift` enum,
    which IS hand-written (not UniFFI-generated) and so is covered by
    the `swift` entry below. One check guards both platforms.

Exit codes:
  0  parity OK
  1  drift found (missing variants in at least one frontend)
  2  bad invocation / missing files

Usage (default workspace layout):
  python3 scripts/check-component-parser-parity.py

Override workspace root:
  python3 scripts/check-component-parser-parity.py --workspace /path/to/vauchi
"""

import argparse
import re
import sys
from pathlib import Path

# Per-frontend variant-name transforms (canonical PascalCase -> frontend form).
TRANSFORMS = {
    "identity": lambda v: v,
    # Swift enum cases lower-camelCase the first letter: Row -> row,
    # QrCode -> qrCode, TextInput -> textInput.
    "lower_first": lambda v: v[:1].lower() + v[1:],
}

# Frontends that hand-roll parsers — each maps to
# (parser file, marker pattern, transform-key). `{V}` in the marker is
# replaced by the (transformed, regex-escaped) variant name.
HAND_ROLLED_PARSERS = {
    "linux-gtk": (
        "linux-gtk/src/core_ui/components/mod.rs",
        # Rust match arm: `Component::Slider {` or `Component::Divider =>`
        r"Component::{V}(\s*\{|\s*=>|\s*\()",
        "identity",
    ),
    "linux-qt": (
        "linux-qt/src/coreui/componentrenderer.cpp",
        # C++ dispatch: `contains("Slider")` (Divider handled as bare string)
        r'(contains\("{V}"\)|"{V}")',
        "identity",
    ),
    "windows": (
        "windows/Vauchi/CoreUI/ComponentRenderer.cs",
        # C# switch expression: `"Slider" => CreateAndRender<...>(...)`
        # or classic `case "Slider":`
        r'(case\s+"{V}"|"{V}"\s*=>)',
        "identity",
    ),
    "android": (
        "android/app/src/main/kotlin/app/vauchi/ui/coreui/Models.kt",
        # Kotlin sealed dispatch: `"Slider" in element` or `"Divider" ->`
        r'"{V}"(\s*in element|\s*->)',
        "identity",
    ),
    "swift": (
        # Shared by iOS + macOS via the CoreUIModels SPM package.
        "vauchi-platform-swift/Sources/CoreUIModels/Models.swift",
        # Swift Decodable enum case: `case row(` or unit `case divider`.
        r"case {V}\b",
        "lower_first",
    ),
    "web-demo": (
        "web-demo/src/core-ui/ComponentRenderer.tsx",
        # SolidJS dispatch on the externally-tagged key: `"Row" in comp`
        # (string-only variants like Divider compared as `"Divider"`).
        r'"{V}"',
        "identity",
    ),
    "tui": (
        "tui/src/ui/widgets/screen_renderer/mod.rs",
        # Rust match arm: `Component::Slider {` or `Component::Divider =>`
        # (same dispatch shape as linux-gtk).
        r"Component::{V}(\s*\{|\s*=>|\s*\()",
        "identity",
    ),
}

# Post-Tier-0 layout is preferred; the pre-Tier-0 single-file layout is
# checked second when both are absent (default workspace lookup only).
ENUM_FILE_CANDIDATES = (
    "core/vauchi-app/src/ui/component/mod.rs",
    "core/vauchi-app/src/ui/component.rs",
)
ENUM_NAME = "Component"


def extract_variants(enum_path: Path, enum_name: str) -> list[str]:
    """Extract variant names from `pub enum {enum_name} { ... }`.

    Recognises both `Variant {`, `Variant(`, and `Variant,` forms.
    """
    text = enum_path.read_text()
    pattern = re.compile(
        rf"pub enum {enum_name}\b[^{{]*\{{(.*?)^\}}",
        re.DOTALL | re.MULTILINE,
    )
    match = pattern.search(text)
    if not match:
        sys.exit(f"error: could not find `pub enum {enum_name}` in {enum_path}")
    body = match.group(1)
    # Variants start at 4-space indent, capital letter, followed by `{`, `(`, or `,`.
    # Strip line comments before matching so `// SomeName` isn't picked up.
    cleaned = re.sub(r"//.*$", "", body, flags=re.MULTILINE)
    variant_re = re.compile(r"^    ([A-Z][A-Za-z0-9_]*)\s*[\{\(,]", re.MULTILINE)
    return sorted(set(variant_re.findall(cleaned)))


def check_parser(
    parser_path: Path, marker_template: str, transform_key: str, variants: list[str]
) -> list[str]:
    """Return the variants whose marker pattern is missing from `parser_path`."""
    if not parser_path.exists():
        return variants  # everything missing
    text = parser_path.read_text()
    transform = TRANSFORMS[transform_key]
    missing = []
    for v in variants:
        pattern = marker_template.replace("{V}", re.escape(transform(v)))
        if not re.search(pattern, text):
            missing.append(v)
    return missing


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--workspace",
        type=Path,
        default=Path(__file__).resolve().parents[2],
        help="Workspace root containing core/, linux-gtk/, etc.",
    )
    parser.add_argument(
        "--enum-file",
        type=Path,
        help="Path to core's component.rs (overrides --workspace lookup).",
    )
    parser.add_argument(
        "--frontend",
        choices=sorted(HAND_ROLLED_PARSERS.keys()),
        help="Check only one frontend (CI per-repo mode).",
    )
    parser.add_argument(
        "--parser-file",
        type=Path,
        help="Path to the parser file (use with --frontend; overrides workspace lookup).",
    )
    args = parser.parse_args()

    if args.enum_file is not None:
        enum_path = args.enum_file
    else:
        enum_path = next(
            (args.workspace / c for c in ENUM_FILE_CANDIDATES if (args.workspace / c).exists()),
            args.workspace / ENUM_FILE_CANDIDATES[0],
        )
    if not enum_path.exists():
        candidates = ", ".join(ENUM_FILE_CANDIDATES)
        print(
            f"error: missing canonical enum file (looked for: {candidates})",
            file=sys.stderr,
        )
        return 2

    variants = extract_variants(enum_path, ENUM_NAME)
    print(f"Canonical {ENUM_NAME} variants ({len(variants)}): {', '.join(variants)}")
    print()

    targets = (
        {args.frontend: HAND_ROLLED_PARSERS[args.frontend]}
        if args.frontend
        else HAND_ROLLED_PARSERS
    )

    drift = False
    for frontend, (rel_path, marker, transform_key) in targets.items():
        parser_path = args.parser_file if args.parser_file else (args.workspace / rel_path)
        missing = check_parser(parser_path, marker, transform_key, variants)
        display_path = str(parser_path) if args.parser_file else rel_path
        if missing:
            drift = True
            print(f"DRIFT  {frontend}: missing {len(missing)} variant(s) in {display_path}")
            for v in missing:
                print(f"         - {v}")
        else:
            print(f"OK     {frontend}: all {len(variants)} variants present in {display_path}")

    print()
    if drift:
        print("FAIL: parser drift detected. Add missing variants or update this gate.")
        return 1
    print("PASS: all hand-rolled parsers cover every Component variant.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
