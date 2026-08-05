#!/usr/bin/env python3
# SPDX-FileCopyrightText: 2026 Mattia Egloff <mattia.egloff@pm.me>
# SPDX-License-Identifier: GPL-3.0-or-later
#
# Markdown-aware `@mention` escaper for MR/PR description bodies.
#
# GitLab and GitHub render bare `@word` as a user mention. Engineering
# docs and commit messages frequently reference Gherkin tags
# (`@implemented`), Swift property wrappers (`@Published`), Kotlin
# annotations (`@JvmStatic`), and similar. They must be wrapped in
# backticks before reaching the platform.
#
# The previous escape pass (`sed 's/@\(...\)/`@\1`/g'`) wrapped every
# match unconditionally, even when the source already had `@word`
# inside an existing code span. The result was broken nesting like
# ``@Published` var x`, which renders as empty inline-code + bare
# `@Published` (autolinked as a mention) + opening backtick. See
# vauchi/ios!370 for the regression that motivated this script.
#
# Algorithm:
#   1. Walk the input character by character.
#   2. Track whether we're inside a single-backtick code span.
#   3. When NOT inside a span and we see `@`, try to match `@<word>`:
#      - If the preceding char is alphanumeric (e.g. `noreply@host`),
#        leave it alone — it's an email.
#      - Otherwise, wrap with backticks.
#   4. Inside a span, leave `@` alone — already escaped.
#
# Fenced code blocks (``` and ~~~) are NOT handled. MR descriptions
# never use fenced blocks for tag references, and adding fenced-block
# parsing increases scope without measurable benefit.

import re
import sys

MENTION_RE = re.compile(r"@([A-Za-z][A-Za-z0-9_-]*)")
EMAIL_LEAD_RE = re.compile(r"[A-Za-z0-9_.+-]")


def escape_mentions(text: str) -> str:
    out: list[str] = []
    i = 0
    in_span = False
    while i < len(text):
        ch = text[i]
        if ch == "`":
            out.append(ch)
            in_span = not in_span
            i += 1
            continue
        if in_span:
            out.append(ch)
            i += 1
            continue
        if ch == "@":
            m = MENTION_RE.match(text, i)
            if m:
                # Email guard: preceding char is alphanumeric/host-y.
                preceding = text[i - 1] if i > 0 else ""
                if preceding and EMAIL_LEAD_RE.match(preceding):
                    out.append(ch)
                    i += 1
                    continue
                out.append(f"`@{m.group(1)}`")
                i = m.end()
                continue
        out.append(ch)
        i += 1
    return "".join(out)


def find_unescaped_mentions(text: str) -> list[str]:
    """Return any bare `@word` that survives escaping. Used as a
    defence-in-depth validator after `escape_mentions`.

    Skips:
      - Inline code spans (already escaped).
      - Anything with a host-y character before the `@`, which is
        exactly `escape_mentions`' EMAIL_LEAD_RE rule. Covers emails
        (`user@host.tld`), GitLab cross-repo commit refs
        (`<word>@<sha>`, which autolink and must not be wrapped), and
        bare `user@host` forms such as SSH key comments
        (`megloff1@Token2-daily`) or account references (`agents@nell`).

    The two halves MUST use the same rule. They did not until
    2026-08-05: this validator carved out only TLD-bearing emails and
    hex commit refs, so a `user@host` with neither was skipped by the
    escaper and then rejected here — aborting `just gitlab mr-update`
    on commit messages that were correct. Narrowing this pattern
    reintroduces that class of false abort."""
    stripped = re.sub(r"`[^`]*`", "", text)
    stripped = re.sub(
        rf"{EMAIL_LEAD_RE.pattern}+@[A-Za-z][A-Za-z0-9_-]*", "", stripped
    )
    return MENTION_RE.findall(stripped)


def main() -> int:
    if len(sys.argv) > 1 and sys.argv[1] == "--check":
        body = sys.stdin.read()
        bare = find_unescaped_mentions(body)
        if bare:
            print(
                "ERROR: MR body contains bare @-mentions after escape pass.",
                file=sys.stderr,
            )
            for m in bare[:5]:
                print(f"  @{m}", file=sys.stderr)
            print(
                "\nThis usually means a commit message had @word inside an "
                "existing code\nspan (e.g. `@Published var x`). Edit the "
                "commit message to use a form\nthat doesn't trigger broken "
                "nesting, or update this script's logic.\n",
                file=sys.stderr,
            )
            return 2
        return 0

    sys.stdout.write(escape_mentions(sys.stdin.read()))
    return 0


if __name__ == "__main__":
    sys.exit(main())
