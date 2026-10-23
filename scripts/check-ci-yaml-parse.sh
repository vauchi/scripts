#!/bin/sh
# SPDX-FileCopyrightText: 2026 Mattia Egloff <mattia.egloff@pm.me>
#
# SPDX-License-Identifier: GPL-3.0-or-later
#
# Parses GitLab CI files as YAML, locally. Server lint reads `local:`
# includes from the default branch, so a syntax error in an include this
# branch edits never reaches it; core!1945 also shipped two syntax errors
# in its top file while server lint was skipped (private#779). GitLab's
# `!reference` tag is accepted. Beyond syntax it checks one thing: every
# script line is a string, since an unquoted `: ` parses as a mapping. It
# does not check keywords; server lint does.
#
# Usage:
#   check-ci-yaml-parse.sh <file>...
#
# Exit: 0 every file parses, 1 a file does not, 2 usage error or no YAML
#       parser (python3 with PyYAML, or uv to fetch it).
#
# Self-test: scripts/tests/check-ci-yaml-parse.test.sh
set -eu

if [ "$#" -eq 0 ]; then
    printf 'check-ci-yaml-parse: usage: %s <file>...\n' "$0" >&2
    exit 2
fi

if python3 -c 'import yaml' 2>/dev/null; then
    set -- python3 - "$@"
elif command -v uv >/dev/null 2>&1; then
    set -- uv run -q --with pyyaml python3 - "$@"
else
    printf 'check-ci-yaml-parse: needs python3 with PyYAML, or uv to fetch it\n' >&2
    exit 2
fi

"$@" <<'EOF'
import sys

import yaml


class CiLoader(yaml.SafeLoader):
    pass


CiLoader.add_constructor(
    "!reference", lambda loader, node: loader.construct_sequence(node)
)

SCRIPT_KEYS = ("script", "before_script", "after_script")


def script_problems(document):
    """Script lines that parsed as something other than a string.

    An unquoted `: ` inside a line turns it into a one-entry mapping —
    valid YAML that GitLab rejects (#767's `echo "ERROR: ..."`)."""
    if not isinstance(document, dict):
        return
    for job, body in document.items():
        if not isinstance(body, dict):
            continue
        for key in SCRIPT_KEYS:
            lines = body.get(key)
            if lines is None or isinstance(lines, str):
                continue
            if not isinstance(lines, list):
                yield f"{job}: {key} is a {type(lines).__name__}, not a list of lines"
                continue
            for number, line in enumerate(lines, 1):
                nested = line if isinstance(line, list) else [line]
                if not all(isinstance(part, str) for part in nested):
                    yield (
                        f"{job}: {key} line {number} is not a string — quote it;"
                        " a ': ' inside an unquoted line makes it a mapping"
                    )


failed = False
for path in sys.argv[1:]:
    try:
        with open(path, encoding="utf-8") as handle:
            document = yaml.load(handle, Loader=CiLoader)
    except (OSError, yaml.YAMLError) as error:
        print(f"  {path}: {error}".replace("\n", "\n    "))
        failed = True
        continue
    for problem in script_problems(document):
        print(f"  {path}: {problem}")
        failed = True
sys.exit(1 if failed else 0)
EOF
