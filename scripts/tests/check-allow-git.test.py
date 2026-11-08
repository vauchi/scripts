#!/usr/bin/env python3
# SPDX-FileCopyrightText: 2026 Mattia Egloff <mattia.egloff@pm.me>
#
# SPDX-License-Identifier: GPL-3.0-or-later

"""Contract tests for check-allow-git.py: every repository's cargo-deny
denies unknown git sources and allows exactly the reviewed ones
(vauchi/private#1162, decisions 3 and 7)."""

import importlib.util
import tempfile
from pathlib import Path

MODULE_PATH = Path(__file__).resolve().parents[1] / "check-allow-git.py"
SPEC = importlib.util.spec_from_file_location("check_allow_git", MODULE_PATH)
assert SPEC and SPEC.loader
CHECK = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(CHECK)

LIST = """\
# reviewed git sources
https://gitlab.com/vauchi/core.git
https://gitlab.com/vauchi/utils/spake2.git
"""

DENY_MATCHING = """\
[sources]
unknown-git = "deny"
allow-git = [
    "https://gitlab.com/vauchi/utils/spake2.git",
    "https://gitlab.com/vauchi/core.git",
]
"""

DENY_MISSING_ONE = """\
[sources]
unknown-git = "deny"
allow-git = ["https://gitlab.com/vauchi/core.git"]
"""

DENY_EXTRA_ONE = """\
[sources]
unknown-git = "deny"
allow-git = [
    "https://gitlab.com/vauchi/core.git",
    "https://gitlab.com/vauchi/utils/spake2.git",
    "https://github.com/someone/fork.git",
]
"""

def write(directory: Path, name: str, text: str) -> Path:
    path = directory / name
    path.write_text(text)
    return path


def test_the_list_ignores_comments_and_blank_lines():
    with tempfile.TemporaryDirectory() as tmp:
        listed = CHECK.read_list(write(Path(tmp), "list.txt", LIST + "\n\n"))
    assert listed == {
        "https://gitlab.com/vauchi/core.git",
        "https://gitlab.com/vauchi/utils/spake2.git",
    }


def test_a_deny_toml_matching_the_list_passes():
    with tempfile.TemporaryDirectory() as tmp:
        deny = write(Path(tmp), "deny.toml", DENY_MATCHING)
        listed = CHECK.read_list(write(Path(tmp), "list.txt", LIST))
        assert CHECK.deny_drift(deny, listed) == []


def test_a_deny_toml_missing_a_listed_source_names_the_line_to_add():
    with tempfile.TemporaryDirectory() as tmp:
        deny = write(Path(tmp), "deny.toml", DENY_MISSING_ONE)
        listed = CHECK.read_list(write(Path(tmp), "list.txt", LIST))
        assert CHECK.deny_drift(deny, listed) == [
            'add "https://gitlab.com/vauchi/utils/spake2.git"'
        ]


def test_a_deny_toml_allowing_an_unreviewed_source_names_the_line_to_remove():
    with tempfile.TemporaryDirectory() as tmp:
        deny = write(Path(tmp), "deny.toml", DENY_EXTRA_ONE)
        listed = CHECK.read_list(write(Path(tmp), "list.txt", LIST))
        assert CHECK.deny_drift(deny, listed) == [
            'remove "https://github.com/someone/fork.git" (not in the reviewed list)'
        ]


def test_a_deny_toml_without_sources_allows_nothing_and_drifts():
    with tempfile.TemporaryDirectory() as tmp:
        deny = write(Path(tmp), "deny.toml", '[licenses]\nallow = ["MIT"]\n')
        listed = CHECK.read_list(write(Path(tmp), "list.txt", LIST))
        assert CHECK.deny_drift(deny, listed) == [
            'set unknown-git = "deny" (is "warn")',
            'add "https://gitlab.com/vauchi/core.git"',
            'add "https://gitlab.com/vauchi/utils/spake2.git"',
        ]


def test_a_deny_toml_that_does_not_deny_unknown_git_drifts():
    # Without unknown-git = "deny" the allow-list restricts nothing: cargo-deny
    # only warns on an unlisted source.
    with tempfile.TemporaryDirectory() as tmp:
        deny = write(Path(tmp), "deny.toml", DENY_MATCHING.replace('"deny"', '"warn"'))
        listed = CHECK.read_list(write(Path(tmp), "list.txt", LIST))
        assert CHECK.deny_drift(deny, listed) == [
            'set unknown-git = "deny" (is "warn")'
        ]


def test_the_command_line_exits_non_zero_on_drift_and_zero_when_clean():
    with tempfile.TemporaryDirectory() as tmp:
        root = Path(tmp)
        listed = write(root, "list.txt", LIST)
        clean = write(root, "clean.toml", DENY_MATCHING)
        drifted = write(root, "drifted.toml", DENY_MISSING_ONE)
        assert CHECK.main(["--list", str(listed), str(clean)]) == 0
        assert CHECK.main(["--list", str(listed), str(clean), str(drifted)]) == 1


if __name__ == "__main__":
    for name, fn in list(globals().items()):
        if name.startswith("test_") and callable(fn):
            fn()
    print("check-allow-git.test: PASS")
