#!/usr/bin/env python3
# SPDX-FileCopyrightText: 2026 Mattia Egloff <mattia.egloff@pm.me>
#
# SPDX-License-Identifier: GPL-3.0-or-later

"""Contract tests for core-pins.py: reading, bumping and checking every
consumer's native Core pin (ADR-026 amendment 2026-09-30, #434)."""

import importlib.util
import json
import subprocess
import sys
import tempfile
from pathlib import Path
from unittest.mock import patch

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


def test_a_commented_out_core_line_is_not_a_pin():
    live = 'vauchi-core = { git = "https://gitlab.com/vauchi/core.git", tag = "v0.69.0", version = "=0.69.0" }\n'
    old = '# vauchi-core = { git = "https://gitlab.com/vauchi/core.git", tag = "v0.60.0" }\n'
    assert PINS.read_pin("cargo", old + live) == "v0.69.0"
    text, crates = PINS.bump_pin("cargo", old + live, "0.70.0")
    assert text.startswith(old), "a comment must be left as written"
    assert crates == ["vauchi-core"]


def test_a_bump_makes_any_version_constraint_exact():
    caret = 'vauchi-core = { git = "https://gitlab.com/vauchi/core.git", tag = "v0.69.0", version = "0.69" }\n'
    text, _ = PINS.bump_pin("cargo", caret, "0.70.0")
    assert text == 'vauchi-core = { git = "https://gitlab.com/vauchi/core.git", tag = "v0.70.0", version = "=0.70.0" }\n'


def test_a_multi_line_dependency_table_is_named_as_unsupported():
    table = '[dependencies.vauchi-core]\ngit = "https://gitlab.com/vauchi/core.git"\ntag = "v0.69.0"\n'
    assert "one-line" in expect_error(PINS.read_pin, "cargo", table)


def test_single_quoted_and_unquoted_ci_refs_are_found_too():
    ci = "  CORE_REF: 'v0.59.0'\n  CORE_REF: v0.59.0\n  CORE_REF: \"v0.59.0\"\n"
    assert [n for n, _ in PINS.hardcoded_ci_refs(ci)] == [1, 2, 3]


def test_a_prerelease_pin_is_judged_by_its_version():
    def status(pin):
        text = CARGO.replace("v0.68.0", pin)
        rows = PINS.check({"consumers": [{"repo": "cli", "kind": "cargo", "file": "Cargo.toml"}]},
                          lambda repo, path: text if path == "Cargo.toml" else None, "v0.69.0")
        return rows[0].status

    assert status("v0.70.0-dev.3") == "current", "a dev tag ahead of the release is current"
    assert status("v0.70.0-rc.1") == "current"
    assert status("v0.69.0-dev.9") == "behind", "a prerelease of the latest release is behind it"
    assert status("v0.68.5") == "behind"
    assert status("main") == "error"


def test_every_reader_names_what_it_could_not_find():
    assert "no version" in expect_error(PINS.read_pin, "cabi-json", "{not json")
    assert "no version" in expect_error(PINS.read_pin, "cabi-json", "{}")
    assert "vauchi-platform-swift" in expect_error(PINS.read_pin, "xcode-spm", "repositoryURL = \"x\";")
    assert "no app.vauchi" in expect_error(PINS.read_pin, "gradle", "")
    assert "disagree" in expect_error(
        PINS.read_pin, "gradle",
        'x("app.vauchi:vauchi-platform:0.69.0")\ny("app.vauchi:vauchi-platform:0.68.0")\n')
    assert "let version" in expect_error(PINS.read_pin, "swift-let-version", "")


def _git(*args, cwd):
    import subprocess
    subprocess.run(["git", "-c", "user.name=t", "-c", "user.email=t@example.invalid",
                    "-c", "init.defaultBranch=main", *args],
                   cwd=cwd, check=True, capture_output=True)


def _cli(*args):
    import subprocess, sys
    return subprocess.run([sys.executable, str(MODULE_PATH), *args], capture_output=True, text=True)


def test_the_command_line_reads_bumps_and_reports_errors():
    import tempfile
    with tempfile.TemporaryDirectory() as tmp:
        manifest = Path(tmp) / "Cargo.toml"
        manifest.write_text(CARGO, encoding="utf-8")
        read = _cli("read", "--kind", "cargo", str(manifest))
        assert (read.returncode, read.stdout) == (0, "v0.68.0\n")

        bump = _cli("bump", "--kind", "cargo", "--version", "0.69.0", str(manifest))
        assert (bump.returncode, bump.stdout) == (0, "vauchi-core\nvauchi-app\nrqrr\n")
        assert PINS.read_pin("cargo", manifest.read_text(encoding="utf-8")) == "v0.69.0"

        missing = _cli("read", "--kind", "cargo", str(Path(tmp) / "absent.toml"))
        assert missing.returncode == 2 and "No such file" in missing.stderr
        refused = _cli("bump", "--kind", "gradle", "--version", "0.69.0", str(manifest))
        assert refused.returncode == 2 and "its own pipeline" in refused.stderr


def test_check_reads_pins_from_git_and_strict_fails_only_on_lag():
    import tempfile
    with tempfile.TemporaryDirectory() as tmp:
        root = Path(tmp)
        core = root / "core"
        (core / "ci").mkdir(parents=True)
        (core / "ci" / "consumer-pins.json").write_text(json.dumps({"consumers": [
            {"repo": "cli", "kind": "cargo", "file": "Cargo.toml", "bumped_by": "bump:consumer-pins"}]}), encoding="utf-8")
        _git("init", "-q", cwd=core)
        _git("add", "-A", cwd=core)
        _git("commit", "-q", "-m", "init", cwd=core)
        _git("tag", "v0.69.0", cwd=core)
        cli = root / "cli"
        cli.mkdir()
        (cli / "Cargo.toml").write_text(CARGO, encoding="utf-8")
        _git("init", "-q", cwd=cli)
        _git("add", "-A", cwd=cli)
        _git("commit", "-q", "-m", "init", cwd=cli)

        lagging = _cli("check", "--root", str(root), "--ref", "main", "--strict")
        assert lagging.returncode == 1, lagging.stdout + lagging.stderr
        assert "behind" in lagging.stdout and "v0.68.0" in lagging.stdout
        assert _cli("check", "--root", str(root), "--ref", "main").returncode == 0, "without --strict it only reports"

        (cli / "Cargo.toml").write_text(PINS.bump_pin("cargo", CARGO, "0.69.0")[0], encoding="utf-8")
        _git("commit", "-q", "-am", "bump", cwd=cli)
        current = _cli("check", "--root", str(root), "--ref", "main", "--strict")
        assert current.returncode == 0, current.stdout + current.stderr
        assert "current" in current.stdout


def test_fetch_reads_the_table_after_fetching_core():
    import tempfile
    with tempfile.TemporaryDirectory() as tmp:
        root = Path(tmp)
        remote = root / "core-remote.git"
        seed = root / "seed"
        seed.mkdir()
        (seed / "README").write_text("core\n", encoding="utf-8")
        _git("init", "-q", cwd=seed)
        _git("add", "-A", cwd=seed)
        _git("commit", "-q", "-m", "init", cwd=seed)
        _git("tag", "v0.69.0", cwd=seed)
        _git("clone", "-q", "--bare", str(seed), str(remote), cwd=root)
        _git("clone", "-q", str(remote), str(root / "core"), cwd=root)

        # The table lands on core's remote after the local clone was made.
        (seed / "ci").mkdir()
        (seed / "ci" / "consumer-pins.json").write_text(json.dumps({"consumers": [
            {"repo": "cli", "kind": "cargo", "file": "Cargo.toml", "bumped_by": "bump:consumer-pins"}]}), encoding="utf-8")
        _git("add", "-A", cwd=seed)
        _git("commit", "-q", "-m", "table", cwd=seed)
        _git("push", "-q", str(remote), "HEAD:main", cwd=seed)

        cli_remote = root / "cli-remote.git"
        cli_seed = root / "cli-seed"
        cli_seed.mkdir()
        (cli_seed / "Cargo.toml").write_text(CARGO, encoding="utf-8")
        _git("init", "-q", cwd=cli_seed)
        _git("add", "-A", cwd=cli_seed)
        _git("commit", "-q", "-m", "init", cwd=cli_seed)
        _git("clone", "-q", "--bare", str(cli_seed), str(cli_remote), cwd=root)
        _git("clone", "-q", str(cli_remote), str(root / "cli"), cwd=root)
        # cli is bumped on its remote after the local clone: only a fetch of
        # cli, listed by the table core just gained, can see it.
        (cli_seed / "Cargo.toml").write_text(PINS.bump_pin("cargo", CARGO, "0.69.0")[0], encoding="utf-8")
        _git("commit", "-q", "-am", "bump", cwd=cli_seed)
        _git("push", "-q", str(cli_remote), "HEAD:main", cwd=cli_seed)

        run = _cli("check", "--root", str(root), "--fetch", "--strict")
        assert run.returncode == 0, run.stdout + run.stderr
        assert "cli" in run.stdout and "current" in run.stdout


PINS_ENV = """\
# The pinned set e2e tests (vauchi/private#1032).
CORE_TAG=v0.96.1
RELAY_SHA=5f3fff43919199602aa316ed6bc68d3ac25bfaef
CLI_SHA=f3b4a851aae4ef902ffb714160077e06138b07f6
"""


def test_a_pins_env_names_its_core_tag():
    # e2e's ci/pins.env carries the Core tag its pinned set runs on, and it
    # must move with e2e's Cargo.toml on every Core release (private#1034).
    assert PINS.read_pin("pins-env", PINS_ENV) == "v0.96.1"
    assert "no CORE_TAG" in expect_error(PINS.read_pin, "pins-env", "# nothing\nRELAY_SHA=abc\n")


def test_bumping_a_pins_env_moves_only_its_core_tag():
    text, crates = PINS.bump_pin("pins-env", PINS_ENV, "0.97.0")
    assert crates == []
    assert text == PINS_ENV.replace("CORE_TAG=v0.96.1", "CORE_TAG=v0.97.0")
    assert "no CORE_TAG" in expect_error(PINS.bump_pin, "pins-env", "RELAY_SHA=abc\n", "0.97.0")


def release_lock(tag="v0.68.0"):
    return f'''version = 4
[[package]]
name = "vauchi-core"
version = "0.68.0"
source = "git+https://gitlab.com/vauchi/core.git?tag={tag}#{'a' * 40}"
'''


def test_merge_gate_accepts_stable_core_and_ignores_other_prereleases():
    text = CARGO + '\nfork = { git = "https://gitlab.com/vauchi/utils/spake2.git", tag = "v0.4.0+vauchi.1" }\n'
    assert PINS.require_release("cargo", text, release_lock()) == "v0.68.0"


def test_merge_gate_rejects_all_non_release_core_tags():
    for tag in ["v0.68.0-dev.6", "v0.69.0-rc.1", "nightly", "main", "v0.68.0+build.1"]:
        text = CARGO.replace('tag = "v0.68.0"', f'tag = "{tag}"')
        assert "not a stable Core release" in expect_error(PINS.require_release, "cargo", text, release_lock(tag))


def test_merge_gate_rejects_a_development_or_mismatched_lock_even_with_stable_manifest():
    for tag in ["v0.68.0-dev.6", "v0.67.0"]:
        assert "locked Core source" in expect_error(PINS.require_release, "cargo", CARGO, release_lock(tag))
    branch_lock = release_lock().replace("tag=v0.68.0", "branch=main")
    assert "locked Core source" in expect_error(PINS.require_release, "cargo", CARGO, branch_lock)


def test_merge_gate_fails_closed_without_a_usable_lock():
    for lock in [None, "not toml", 'version = 4\n', release_lock().replace('a' * 40, 'bad')]:
        assert expect_error(PINS.require_release, "cargo", CARGO, lock)


def test_merge_gate_checks_every_locked_core_source():
    lock = release_lock() + release_lock("v0.68.0-dev.6").removeprefix("version = 4\n")
    assert "locked Core source" in expect_error(PINS.require_release, "cargo", CARGO, lock)


def test_merge_gate_rejects_a_patched_core_even_when_app_keeps_a_stable_git_source():
    app = release_lock().replace('name = "vauchi-core"', 'name = "vauchi-app"')
    core = '\n[[package]]\nname = "vauchi-core"\nversion = "0.68.0"\n'
    for source in ["", 'source = "git+https://gitlab.com/example/fork.git?tag=v0.68.0#' + 'a' * 40 + '"\n']:
        assert "locked Core source" in expect_error(PINS.require_release, "cargo", CARGO, app + core + source)


def test_merge_gate_rejects_a_development_commit_relabeled_as_a_stable_tag():
    assert PINS.require_release("cargo", CARGO, release_lock(), "a" * 40) == "v0.68.0"
    assert "locked Core source" in expect_error(PINS.require_release, "cargo", CARGO, release_lock(), "b" * 40)


def test_published_release_resolution_handles_lightweight_and_annotated_tags():
    ref = "refs/tags/v0.68.0"
    for output, expected in [
        (f"{'a' * 40}\t{ref}\n", "a" * 40),
        (f"{'a' * 40}\t{ref}\n{'b' * 40}\t{ref}^{{}}\n", "b" * 40),
    ]:
        result = subprocess.CompletedProcess([], 0, stdout=output, stderr="")
        with patch.object(PINS.subprocess, "run", return_value=result):
            assert PINS.release_tag_commit("v0.68.0") == expected
    for status, output in [(1, ""), (0, ""), (0, f"bad\t{ref}\n")]:
        result = subprocess.CompletedProcess([], status, stdout=output, stderr="")
        with patch.object(PINS.subprocess, "run", return_value=result):
            assert "could not verify" in expect_error(PINS.release_tag_commit, "v0.68.0")
    with patch.object(PINS.subprocess, "run", side_effect=subprocess.TimeoutExpired("git", 30)):
        assert "could not verify" in expect_error(PINS.release_tag_commit, "v0.68.0")


def test_merge_gate_command_fails_on_development_pins_and_passes_after_restoring_both_files():
    with tempfile.TemporaryDirectory() as directory:
        manifest = Path(directory) / "Cargo.toml"
        lock = Path(directory) / "Cargo.lock"
        for tag, locked_tag, status, message in [
            ("v0.68.0-dev.6", "v0.68.0-dev.6", 2, "not a stable Core release"),
            ("v0.68.0", "v0.68.0-dev.6", 2, "locked Core source"),
            ("v0.68.0", "v0.68.0", 0, "Stable Core pin: v0.68.0"),
        ]:
            manifest.write_text(CARGO.replace('tag = "v0.68.0"', f'tag = "{tag}"'), encoding="utf-8")
            lock.write_text(release_lock(locked_tag), encoding="utf-8")
            result = subprocess.run(
                [sys.executable, str(MODULE_PATH), "require-release", "--kind", "cargo", str(manifest), "--lockfile", str(lock)],
                capture_output=True, text=True, check=False,
            )
            assert result.returncode == status, result.stderr
            assert message in result.stdout + result.stderr


def test_merge_gate_supports_other_native_core_pin_files():
    assert PINS.require_release("ref-file", "v0.68.0\n") == "v0.68.0"
    assert "not a stable Core release" in expect_error(PINS.require_release, "pins-env", "CORE_TAG=v0.68.0-dev.6\n")


if __name__ == "__main__":
    for name, fn in list(globals().items()):
        if name.startswith("test_") and callable(fn):
            fn()
    print("core-pins.test: PASS")
