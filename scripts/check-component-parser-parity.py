#!/usr/bin/env python3
# SPDX-FileCopyrightText: 2026 Mattia Egloff <mattia.egloff@pm.me>
# SPDX-License-Identifier: GPL-3.0-or-later
"""Check that every frontend's ScreenModel parser handles every current
Component variant and does not retain known retired wire variants.

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
The inverse drift is dangerous too: a retired parser arm can keep dead UI and
frontend-invented actions alive after core has removed that wire contract.

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

PRESENTATION_PARSERS = {
    "linux-gtk": (
        "linux-gtk/src/core_ui/generic_surface",
        r"PresentationNode::{V}\b",
        "identity",
    ),
    "linux-qt": (
        "linux-qt/src/coreui",
        r'"{V}"',
        "identity",
    ),
    "windows": (
        "windows-display/src/Vauchi.Display/PresentationSurface.cs",
        r'"{V}"',
        "identity",
    ),
    "android": (
        "android/app/src/main/kotlin/app/vauchi/ui/presentation/PresentationParser.kt",
        r'"{V}"',
        "identity",
    ),
    "ios": (
        "ios/Vauchi/CoreUI/PresentationNodes.swift",
        r'"{V}"',
        "identity",
    ),
    "macos": (
        "macos/Vauchi/CoreUI/PresentationNodes.swift",
        r'"{V}"',
        "identity",
    ),
    "tui": (
        "tui/src/ui/presentation_renderer",
        r"PresentationNode::{V}\b",
        "identity",
    ),
    "web-demo": (
        "web-demo/src/presentation/PresentationNodeRenderer.tsx",
        r'"{V}"',
        "identity",
    ),
}

# These tags were removed from the canonical Component enum before the first
# public release. Confirmation is represented by InlineConfirm, toast is an
# ActionResult, and web's old domain-shaped variants were replaced by the
# generic Preview/List variants. They must not return in core or any parser.
RETIRED_VARIANTS = (
    "CardPreview",
    "ConfirmationDialog",
    "ContactList",
    "ShowToast",
)

# Some retired component names are still valid in another wire enum living in
# the same large parser file. `ShowToast` is an ActionResult, so Android and
# Swift need a component-specific marker instead of their generic variant
# marker to avoid a false positive.
RETIRED_MARKER_OVERRIDES = {
    "android": {
        "ShowToast": r"\bdata class ShowToast\s*\([^)]*\)\s*:\s*Component\s*\(\s*\)",
    },
    "swift": {
        "ShowToast": r"\bcase showToast\s*\(\s*ShowToastComponent\b",
    },
}

# Post-Tier-0 layout is preferred; the pre-Tier-0 single-file layout is
# checked second when both are absent (default workspace lookup only).
ENUM_FILE_CANDIDATES = (
    "core/vauchi-app/src/ui/component/mod.rs",
    "core/vauchi-app/src/ui/component.rs",
)
ENUM_NAME = "Component"
PRESENTATION_ENUM_FILE_CANDIDATES = (
    "contract/src/presentation/surface/nodes.rs",
    "core/vauchi-core/src/platform/presentation/surface/nodes.rs",
)


def extract_variants(enum_path: Path, enum_name: str) -> list[str]:
    """Extract variant names from `pub enum {enum_name} { ... }`.

    Recognises both `Variant {`, `Variant(`, and `Variant,` forms.
    """
    text = enum_path.read_text(encoding="utf-8")
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


# ADR-078 renamed linux-gtk and linux-qt (private#1029). The tables keep
# the shell names; a workspace that already has the new directory is read
# there. Looking under one name only would skip the shell and pass.
RENAMED_DIRS = {
    "linux-gtk": "gtk-display",
    "linux-qt": "qt-display",
    "windows": "windows-app",
    "tui": "tui-display",
}


def in_workspace(root: Path, rel: str) -> Path:
    if rel.startswith("android/app/src/main/kotlin/app/vauchi/ui/presentation/"):
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


def check_parser(
    parser_path: Path, marker_template: str, transform_key: str, variants: list[str]
) -> list[str]:
    """Return the variants whose marker pattern is missing from `parser_path`."""
    if not parser_path.exists():
        return variants  # everything missing
    text = parser_text(parser_path)
    transform = TRANSFORMS[transform_key]
    missing = []
    for v in variants:
        pattern = marker_template.replace("{V}", re.escape(transform(v)))
        if not re.search(pattern, text):
            missing.append(v)
    return missing


def present_variants(
    frontend: str,
    parser_path: Path,
    marker_template: str,
    transform_key: str,
    variants: tuple[str, ...],
) -> list[str]:
    """Return retired variants whose dispatch marker is present."""
    if not parser_path.exists():
        return []
    text = parser_text(parser_path)
    transform = TRANSFORMS[transform_key]
    present = []
    for variant in variants:
        pattern = RETIRED_MARKER_OVERRIDES.get(frontend, {}).get(variant)
        if pattern is None:
            pattern = marker_template.replace("{V}", re.escape(transform(variant)))
        if re.search(pattern, text):
            present.append(variant)
    return present


def parser_text(parser_path: Path) -> str:
    """Read one parser file or concatenate a split parser directory."""
    if parser_path.is_dir():
        return "\n".join(
            path.read_text(encoding="utf-8")
            for path in sorted(parser_path.rglob("*"))
            if path.is_file() and path.suffix in {".rs", ".cpp", ".cs", ".kt", ".swift", ".tsx"}
        )
    return parser_path.read_text(encoding="utf-8")


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--protocol",
        choices=("component", "presentation"),
        default="component",
        help="Canonical wire protocol to audit.",
    )
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
        choices=sorted(set(HAND_ROLLED_PARSERS) | set(PRESENTATION_PARSERS)),
        help="Check only one frontend (CI per-repo mode).",
    )
    parser.add_argument(
        "--parser-file",
        type=Path,
        help="Path to the parser file (use with --frontend; overrides workspace lookup).",
    )
    args = parser.parse_args()

    enum_candidates = (
        PRESENTATION_ENUM_FILE_CANDIDATES
        if args.protocol == "presentation"
        else ENUM_FILE_CANDIDATES
    )
    enum_name = "PresentationNode" if args.protocol == "presentation" else ENUM_NAME
    parser_map = (
        PRESENTATION_PARSERS if args.protocol == "presentation" else HAND_ROLLED_PARSERS
    )
    if args.frontend and args.frontend not in parser_map:
        parser.error(f"{args.frontend} has no {args.protocol} parser configuration")

    if args.enum_file is not None:
        enum_path = args.enum_file
    else:
        enum_path = next(
            (args.workspace / c for c in enum_candidates if (args.workspace / c).exists()),
            args.workspace / enum_candidates[0],
        )
        if args.protocol == "presentation":
            contract_lib = args.workspace / "contract/src/lib.rs"
            lib_text = contract_lib.read_text(encoding="utf-8") if contract_lib.is_file() else ""
            contract_declared = (args.workspace / "contract/src/presentation").is_dir() or re.search(
                r"(?m)^\s*(?:pub(?:\([^)]*\))?\s+)?mod\s+presentation\s*;", lib_text
            )
            if contract_declared:
                enum_path = args.workspace / enum_candidates[0]
    if not enum_path.exists():
        candidates = ", ".join(enum_candidates)
        print(
            f"error: missing canonical enum file (looked for: {candidates})",
            file=sys.stderr,
        )
        return 2

    variants = extract_variants(enum_path, enum_name)
    print(f"Canonical {enum_name} variants ({len(variants)}): {', '.join(variants)}")
    print()

    retired_variants = RETIRED_VARIANTS if args.protocol == "component" else ()
    reintroduced = sorted(set(variants).intersection(retired_variants))
    if reintroduced:
        print(
            "FAIL: canonical Component reintroduced retired variant(s): "
            + ", ".join(reintroduced)
        )
        return 1

    targets = (
        {args.frontend: parser_map[args.frontend]}
        if args.frontend
        else parser_map
    )

    drift = False
    for frontend, (rel_path, marker, transform_key) in targets.items():
        parser_path = args.parser_file if args.parser_file else in_workspace(args.workspace, rel_path)
        missing = check_parser(parser_path, marker, transform_key, variants)
        retired = present_variants(
            frontend, parser_path, marker, transform_key, retired_variants
        )
        display_path = str(parser_path)
        if missing:
            drift = True
            print(f"DRIFT  {frontend}: missing {len(missing)} variant(s) in {display_path}")
            for v in missing:
                print(f"         - {v}")
        if retired:
            drift = True
            print(f"DRIFT  {frontend}: retains {len(retired)} retired variant(s) in {display_path}")
            for v in retired:
                print(f"         - {v}")
        if not missing and not retired:
            print(f"OK     {frontend}: all {len(variants)} variants present in {display_path}")

    print()
    if drift:
        print("FAIL: parser drift detected. Add missing variants or remove retired variants.")
        return 1
    print(f"PASS: all hand-rolled parsers cover every {enum_name} variant.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
