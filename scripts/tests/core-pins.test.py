#!/usr/bin/env python3
# SPDX-FileCopyrightText: 2026 Mattia Egloff <mattia.egloff@pm.me>
#
# SPDX-License-Identifier: GPL-3.0-or-later

"""Contract tests for core-pins.py: reading, bumping and checking every
consumer's native Core pin (ADR-026 amendment 2026-09-30, #434)."""

import importlib.util
import json
from pathlib import Path

MODULE_PATH = Path(__file__).resolve().parents[1] / "core-pins.py"
SPEC = importlib.util.spec_from_file_location("core_pins", MODULE_PATH)
assert SPEC and SPEC.loader
PINS = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(PINS)

CARGO = """\
[dependencies]
serde = { version = "1", features = ["derive"] }
vauchi-core = { git = "https://gitlab.com/vauchi/core.git", tag = "v0.68.0", version = "=0.68.0", features = ["network"] }
vauchi-app = { git = "https://gitlab.com/vauchi/core.git", tag = "v0.68.0", version = "=0.68.0", default-features = false }
rqrr = { git = "https://gitlab.com/vauchi/core.git", tag = "v0.68.0" }
other = { git = "https://gitlab.com/vauchi/other.git", tag = "v0.68.0", version = "=0.68.0" }
"""

PBXPROJ = """\
		AAAA /* XCRemoteSwiftPackageReference "swift-snapshot-testing" */ = {
			isa = XCRemoteSwiftPackageReference;
			repositoryURL = "https://github.com/pointfreeco/swift-snapshot-testing";
			requirement = {
				kind = exactVersion;
				version = 1.17.0;
			};
		};
		BBBB /* XCRemoteSwiftPackageReference "vauchi-platform-swift" */ = {
			isa = XCRemoteSwiftPackageReference;
			repositoryURL = "https://gitlab.com/vauchi/vauchi-platform-swift.git";
			requirement = {
				kind = exactVersion;
				version = 0.69.0;
			};
		};
"""


def expect_error(fn, *args):
    try:
        fn(*args)
    except PINS.PinError as err:
        return str(err)
    raise AssertionError(f"{fn.__name__}{args!r} should raise PinError")


def test_reads_every_pin_kind():
    assert PINS.read_pin("cargo", CARGO) == "v0.68.0"
    assert PINS.read_pin("ref-file", "# Core release this app builds against\nv0.68.0\n") == "v0.68.0"
    assert PINS.read_pin("cabi-json", json.dumps({"version": "0.69.0", "sha256": "ab"})) == "v0.69.0"
    assert PINS.read_pin("xcode-spm", PBXPROJ) == "v0.69.0"
    assert PINS.read_pin(
        "gradle",
        'implementation("app.vauchi:vauchi-platform:0.69.0")\n'
        'screenshotTestImplementation("app.vauchi:vauchi-platform:0.69.0")\n',
    ) == "v0.69.0"
    assert PINS.read_pin("swift-let-version", 'let version = "0.69.0"\n') == "v0.69.0"


def test_a_floating_or_disagreeing_cargo_pin_is_an_error():
    floating = 'vauchi-protocol = { git = "https://gitlab.com/vauchi/core.git", branch = "main" }\n'
    assert "not pinned to a tag" in expect_error(PINS.read_pin, "cargo", floating)

    split = CARGO.replace('rqrr = { git = "https://gitlab.com/vauchi/core.git", tag = "v0.68.0" }',
                          'rqrr = { git = "https://gitlab.com/vauchi/core.git", tag = "v0.67.0" }')
    assert "disagree" in expect_error(PINS.read_pin, "cargo", split)

    assert "no Core dependency" in expect_error(PINS.read_pin, "cargo", '[dependencies]\nserde = "1"\n')
    assert "no Core ref" in expect_error(PINS.read_pin, "ref-file", "# nothing here\n")
    assert "unknown pin kind" in expect_error(PINS.read_pin, "npm", "")


def test_bumping_a_cargo_pin_moves_every_core_line_and_nothing_else():
    text, crates = PINS.bump_pin("cargo", CARGO, "0.69.0")

    assert PINS.read_pin("cargo", text) == "v0.69.0"
    assert 'vauchi-core = { git = "https://gitlab.com/vauchi/core.git", tag = "v0.69.0", version = "=0.69.0", features = ["network"] }' in text
    assert 'rqrr = { git = "https://gitlab.com/vauchi/core.git", tag = "v0.69.0" }' in text
    assert 'other = { git = "https://gitlab.com/vauchi/other.git", tag = "v0.68.0", version = "=0.68.0" }' in text
    assert 'serde = { version = "1", features = ["derive"] }' in text
    assert crates == ["vauchi-core", "vauchi-app", "rqrr"]


def test_bumping_a_floating_cargo_pin_pins_it():
    floating = 'vauchi-protocol = { git = "https://gitlab.com/vauchi/core.git", branch = "main" }\n'
    text, crates = PINS.bump_pin("cargo", floating, "0.69.0")
    assert text == 'vauchi-protocol = { git = "https://gitlab.com/vauchi/core.git", tag = "v0.69.0" }\n'
    assert crates == ["vauchi-protocol"]


def test_bumping_a_ref_file_keeps_its_comment():
    text, crates = PINS.bump_pin("ref-file", "# Core release this app builds against\nv0.68.0\n", "0.69.0")
    assert text == "# Core release this app builds against\nv0.69.0\n"
    assert crates == []


def test_kinds_bumped_elsewhere_are_refused():
    assert "bumped by its own pipeline" in expect_error(PINS.bump_pin, "xcode-spm", PBXPROJ, "0.70.0")


def test_the_latest_release_ignores_prereleases_and_sorts_numerically():
    tags = ["v0.9.0", "v0.10.0", "v0.10.1-rc.1", "v0.10.0-dev.3", "vendor-x", "v0.10.0"]
    assert PINS.latest_release_tag(tags) == "v0.10.0"
    assert "no release tag" in expect_error(PINS.latest_release_tag, ["v1.0.0-rc.1"])


def test_ci_jobs_that_hard_code_a_core_ref_are_found():
    ci = 'variables:\n  VAUCHI_CORE_REF: v0.68.0\ncheck:\n  variables:\n    CORE_REF: "v0.59.0"\n    PARSER_FILE: x\n'
    assert PINS.hardcoded_ci_refs(ci) == [(2, "VAUCHI_CORE_REF: v0.68.0"), (5, 'CORE_REF: "v0.59.0"')]
    assert PINS.hardcoded_ci_refs('  CORE_PIN_FILE: core-ref\n  CORE_REF: "main"\n') == []


def test_check_reports_lag_errors_and_hardcoded_ci_refs():
    table = {"consumers": [
        {"repo": "cli", "kind": "cargo", "file": "Cargo.toml", "bumped_by": "bump:consumer-pins"},
        {"repo": "windows", "kind": "cabi-json", "file": "cabi-version.json", "bumped_by": "trigger:windows"},
        {"repo": "linux-qt", "kind": "ref-file", "file": "core-ref", "bumped_by": "bump:consumer-pins"},
    ]}
    files = {
        ("cli", "Cargo.toml"): CARGO,
        ("windows", "cabi-version.json"): '{"version": "0.69.0"}',
        ("windows", ".gitlab-ci.yml"): '    CORE_REF: "v0.59.0"\n',
    }
    rows = PINS.check(table, lambda repo, path: files.get((repo, path)), "v0.69.0")
    by_repo = {row.repo: row for row in rows}

    assert (by_repo["cli"].pin, by_repo["cli"].status) == ("v0.68.0", "behind")
    assert by_repo["windows"].status == "hardcoded-ci-ref"
    assert "line 1" in by_repo["windows"].note
    assert by_repo["linux-qt"].status == "error"
    assert PINS.failed(rows)

    files[("cli", "Cargo.toml")] = PINS.bump_pin("cargo", CARGO, "0.69.0")[0]
    files[("windows", ".gitlab-ci.yml")] = "    CORE_PIN_FILE: cabi-version.json\n"
    files[("linux-qt", "core-ref")] = "v0.69.0\n"
    rows = PINS.check(table, lambda repo, path: files.get((repo, path)), "v0.69.0")
    assert [row.status for row in rows] == ["current", "current", "current"]
    assert not PINS.failed(rows)


if __name__ == "__main__":
    for name, fn in list(globals().items()):
        if name.startswith("test_") and callable(fn):
            fn()
    print("core-pins.test: PASS")
