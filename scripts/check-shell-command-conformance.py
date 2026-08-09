#!/usr/bin/env python3
# SPDX-FileCopyrightText: 2026 Mattia Egloff <mattia.egloff@pm.me>
#
# SPDX-License-Identifier: GPL-3.0-or-later
"""A shell that acts on one half of a command pair must handle the other.

Core emits `DismissOverlay` to close a menu it opened with
`PresentOverlay`. A shell that renders the first and ignores the second
leaves the menu on screen over the destination the user just chose — and
says nothing, because an unhandled command falls into a generic effect.
That shipped on Android (`vauchi/android!621`), on iOS
(`problems/2026-08-07-ios-stale-overlay-and-raw-error-alert`, priority
critical) and on web-demo, each found by hand, months apart.

The pairing is the invariant worth checking: nothing about the *content*
of a shell's overlay code says whether it can close one, but the absence
of the counterpart command is mechanical.

## Exemptions carry reasons

A gap is not automatically a defect. Windows and linux-qt raise their
overlay as a modal dialog they close themselves on selection, so Core's
dismissal is redundant there — a real conformance gap with no
user-visible symptom. Those live in the allowlist with a stated reason,
because an exemption nobody has to justify is how a check stops meaning
anything (see `_private/docs/lint-errors/cc21-chestertons-fence`).

## What this cannot do

Detection is textual: it sees whether a shell's sources mention the
command, not whether the arm it reaches actually fires. iOS mentioned
`DismissOverlay`, decoded it, had a test named for it — and the bug was
still live, because the shell was built against a stale artifact. So a
green run here means "the counterpart is handled somewhere", never "the
behaviour works". Behaviour needs a device.

Usage:
  check-shell-command-conformance.py [workspace_root]

Exit: 0 when every gap is allowlisted; 1 on an unlisted gap; 2 on
      usage/IO error.
"""
import pathlib
import re
import sys

# (present, dismiss) — acting on the first obliges handling the second.
COMMAND_PAIRS = [("PresentOverlay", "DismissOverlay")]

# Shell directories and the source extensions worth scanning in each.
SHELLS = {
    "android": (".kt", ".kts"),
    "ios": (".swift",),
    "macos": (".swift",),
    "tui": (".rs",),
    "linux-gtk": (".rs", ".py"),
    "linux-qt": (".cpp", ".h"),
    "windows": (".cs",),
    "web-demo": (".ts", ".tsx"),
}

SKIP_DIRS = {
    "build", "target", "node_modules", ".git", "obj", "bin",
    "DerivedData", "Pods", "dist", "generated", "Generated",
}

ALLOW_FILE = "shell-command-conformance-allow.txt"


def is_test_path(path: pathlib.Path) -> bool:
    parts = {p.lower() for p in path.parts}
    if parts & {"tests", "test", "spec", "__tests__", "uitests"}:
        return True
    return bool(re.search(r"(^|[._-])(test|tests|spec)s?\.", path.name.lower()))


def mentions(root: pathlib.Path, exts: tuple, needle: str) -> bool:
    """Does any non-test source file under `root` mention `needle`?

    Tests are excluded deliberately: a shell whose only reference is in a
    test has not wired the command, and counting it would let the check
    pass on a shell that cannot act.
    """
    pattern = re.compile(rf"\b{re.escape(needle)}\b")
    for path in root.rglob("*"):
        if not path.is_file() or path.suffix not in exts:
            continue
        if SKIP_DIRS & set(path.parts) or is_test_path(path):
            continue
        try:
            if pattern.search(path.read_text(errors="ignore")):
                return True
        except OSError:
            continue
    return False


def load_allowlist(script_dir: pathlib.Path) -> dict:
    """`shell command  # reason` per line. The reason is mandatory."""
    allow = {}
    path = script_dir / ALLOW_FILE
    if not path.exists():
        return allow
    for lineno, raw in enumerate(path.read_text().splitlines(), 1):
        line = raw.strip()
        if not line or line.startswith("#"):
            continue
        entry, _, reason = line.partition("#")
        fields = entry.split()
        if len(fields) != 2 or not reason.strip():
            print(
                f"{path}:{lineno}: expected `<shell> <command>  # reason`",
                file=sys.stderr,
            )
            raise SystemExit(2)
        allow[(fields[0], fields[1])] = reason.strip()
    return allow


def main() -> int:
    root = pathlib.Path(sys.argv[1] if len(sys.argv) > 1 else ".").resolve()
    allow = load_allowlist(pathlib.Path(__file__).resolve().parent)

    gaps, exempt = [], []
    for shell, exts in sorted(SHELLS.items()):
        shell_dir = root / shell
        if not shell_dir.is_dir():
            continue
        for present, dismiss in COMMAND_PAIRS:
            if not mentions(shell_dir, exts, present):
                continue  # does not act on the pair at all
            if mentions(shell_dir, exts, dismiss):
                continue
            reason = allow.get((shell, dismiss))
            (exempt if reason else gaps).append((shell, present, dismiss, reason))

    for shell, present, dismiss, reason in exempt:
        print(f"  exempt  {shell}: handles {present}, not {dismiss} — {reason}")
    for shell, present, dismiss, _ in gaps:
        print(f"  GAP     {shell}: handles {present} but never {dismiss}")

    if not gaps and not exempt:
        print("  every shell that acts on a command pair handles both halves")

    if gaps:
        print()
        print("A shell that renders an overlay but cannot close one leaves it")
        print("over the destination, silently — an unhandled command becomes a")
        print("generic effect and nothing reports it.")
        print(f"Fix the shell, or add a reason to scripts/{ALLOW_FILE}.")
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
