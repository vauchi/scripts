#!/usr/bin/env python3
# SPDX-FileCopyrightText: 2026 Mattia Egloff <mattia.egloff@pm.me>
#
# SPDX-License-Identifier: GPL-3.0-or-later
"""A shell that acts on one half of a command pair must handle the other.

Core opens a menu with `PresentOverlay` and closes it with
`DismissOverlay`. A shell that renders the first and ignores the second
leaves the menu over the destination the user just chose — and says
nothing, because an unhandled command falls into a generic effect. That
shipped on Android (`vauchi/android!621`), on iOS
(`problems/2026-08-07-ios-stale-overlay-and-raw-error-alert`, priority
critical) and on web-demo, each found by hand, months apart.

The pairing is the invariant worth checking: nothing about the *content*
of a shell's overlay code says whether it can close one, but the absence
of the counterpart command is mechanical.

## Exemptions live with the shell, not here

A gap is not automatically a defect — Windows and linux-qt raise a modal
dialog they close themselves, so Core's dismissal is redundant there.
Each shell records its own exemptions in
`.shell-command-conformance-allowlist` at its repo root, matching the
`.file-size-baseline` / `.domain-named-views-allowlist` convention.

That placement is deliberate: the reason describes that shell's code, a
shell can justify a gap in its own MR without touching this repo, and the
justification is reviewed by the people who own the code it describes.

Format, one per line — the reason is mandatory and the file is rejected
without one:

    DismissOverlay  # ContentDialog closes itself on click

## Modes

    --shell <name> [root]   check one shell; `root` is that shell's
                            checkout (default `.`). This is the CI mode:
                            each repo checks itself, gating the MR that
                            can break it.
    [root]                  check every shell directory under a workspace
                            checkout.

## What this cannot do

Detection is textual: it sees whether a shell's sources mention the
command, not whether the arm it reaches actually fires. iOS mentioned
`DismissOverlay`, decoded it, had a test named for it — and was still
broken on device, because the build had resolved a stale artifact. A
green run means "the counterpart is handled somewhere", never "the
behaviour works". Behaviour needs a device.

Exit: 0 when every gap is allowlisted; 1 on an unlisted gap; 2 on
      usage/IO error.
"""
import pathlib
import re
import sys

# (present, dismiss) — acting on the first obliges handling the second.
COMMAND_PAIRS = [("PresentOverlay", "DismissOverlay")]

# Shell name -> source extensions worth scanning.
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
    "build", "build-local", "target", "node_modules", ".git", "obj", "bin",
    "DerivedData", "Pods", "dist", "generated", "Generated",
}

ALLOWLIST = ".shell-command-conformance-allowlist"


def is_test_path(path: pathlib.Path) -> bool:
    parts = {p.lower() for p in path.parts}
    if parts & {"tests", "test", "spec", "__tests__", "uitests"}:
        return True
    return bool(re.search(r"(^|[._-])(test|tests|spec)s?\.", path.name.lower()))


def mentions(root: pathlib.Path, exts: tuple, needle: str) -> bool:
    """Does any non-test source file under `root` mention `needle`?

    Tests are excluded deliberately: a shell whose only reference is in a
    test has not wired the command, and counting it would let this pass
    on a shell that cannot act.
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


def load_allowlist(shell_dir: pathlib.Path) -> dict:
    """`<command>  # reason` per line, from the shell's own repo root."""
    allow = {}
    path = shell_dir / ALLOWLIST
    if not path.exists():
        return allow
    for lineno, raw in enumerate(path.read_text().splitlines(), 1):
        line = raw.strip()
        if not line or line.startswith("#"):
            continue
        command, _, reason = line.partition("#")
        if not command.split() or not reason.strip():
            print(
                f"{path}:{lineno}: expected `<command>  # reason` — an "
                f"exemption without a stated reason is how a check stops "
                f"meaning anything",
                file=sys.stderr,
            )
            raise SystemExit(2)
        allow[command.split()[0]] = reason.strip()
    return allow


def check_shell(shell: str, shell_dir: pathlib.Path) -> tuple:
    """Returns (gaps, exemptions) for one shell."""
    exts = SHELLS[shell]
    allow = load_allowlist(shell_dir)
    gaps, exempt = [], []
    for present, dismiss in COMMAND_PAIRS:
        if not mentions(shell_dir, exts, present):
            continue  # does not act on the pair at all
        if mentions(shell_dir, exts, dismiss):
            continue
        reason = allow.get(dismiss)
        (exempt if reason else gaps).append((shell, present, dismiss, reason))
    return gaps, exempt


def main() -> int:
    args = sys.argv[1:]
    single = None
    if args and args[0] == "--shell":
        if len(args) < 2 or args[1] not in SHELLS:
            print(
                f"usage: {sys.argv[0]} --shell <{'|'.join(sorted(SHELLS))}> [root]",
                file=sys.stderr,
            )
            return 2
        single = args[1]
        args = args[2:]
    root = pathlib.Path(args[0] if args else ".").resolve()

    gaps, exempt = [], []
    if single:
        g, e = check_shell(single, root)
        gaps += g
        exempt += e
    else:
        for shell in sorted(SHELLS):
            shell_dir = root / shell
            if shell_dir.is_dir():
                g, e = check_shell(shell, shell_dir)
                gaps += g
                exempt += e

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
        print(f"Fix the shell, or add a reason to its {ALLOWLIST}.")
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
