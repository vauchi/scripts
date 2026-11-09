#!/usr/bin/env python3
# SPDX-FileCopyrightText: 2026 Mattia Egloff <mattia.egloff@pm.me>
#
# SPDX-License-Identifier: GPL-3.0-or-later

"""Contract tests for main-retest-plan.py: main re-runs only the marked jobs
that did not pass in an MR pipeline on the identical tree, and anything in
doubt runs everything (vauchi/private#1179, decision 8)."""

import importlib.util
from pathlib import Path

import yaml

MODULE_PATH = Path(__file__).resolve().parents[1] / "main-retest-plan.py"
SPEC = importlib.util.spec_from_file_location("main_retest_plan", MODULE_PATH)
assert SPEC and SPEC.loader
PLAN = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(PLAN)

MARK = {"if": '$CI_PIPELINE_SOURCE == "push" && $CI_COMMIT_BRANCH == $CI_DEFAULT_BRANCH && $MAIN_RETEST != "off"',
        "when": "never"}
MAIN = {"if": "$CI_COMMIT_BRANCH == $CI_DEFAULT_BRANCH"}

# GitLab's merged YAML for a repository: includes inlined, !reference
# resolved, extends kept with the hidden jobs it names, and stages listed
# with .pre first and .post last.
STAGES = [".pre", "build", "test", "deploy", ".post"]
MERGED = {
    "stages": STAGES,
    "variables": {"FOO": "1"},
    "workflow": {"rules": [{"if": '$CI_PIPELINE_SOURCE == "merge_request_event"'}, MAIN]},
    ".runner": {"tags": ["docker"]},
    "build:debug": {"extends": ".runner", "stage": "build", "script": ["make"], "rules": [MARK, MAIN]},
    "test:unit": {"extends": ".runner", "stage": "test", "script": ["make test"],
                  "needs": ["build:debug"], "rules": [MARK, MAIN]},
    "test:ui": {"stage": "test", "script": ["make ui"], "allow_failure": True,
                "needs": [{"job": "build:debug", "artifacts": True}], "rules": [MARK, MAIN]},
    "lint:format": {"stage": "build", "script": ["fmt"], "rules": [MAIN]},
    "test:docs": {"stage": "test", "script": ["make docs"], "rules": [MARK, MAIN],
                  "needs": [{"job": "lint:format", "optional": True}]},
    # GitLab's merged YAML keeps a `!reference` in rules as a nested list.
    "test:nested": {"stage": "test", "script": ["make nested"], "rules": [[MARK], [MAIN]]},
    # The plan and trigger jobs name $MAIN_RETEST too, but run in main: unmarked.
    "main:retest-plan": {"stage": ".pre", "script": ["plan"], "rules": [{"if": MARK["if"]}]},
    # A hidden job that extends a visible one (security.yml's .sast-analyzer
    # extends sast): a child without sast must not keep it.
    "sast": {"stage": "test", "script": ["sast"], "rules": [MAIN]},
    ".sast-analyzer": {"extends": "sast", "allow_failure": True},
    "github-mirror": {"stage": "deploy", "script": ["mirror"], "rules": [MAIN]},
}
MARKED = {"build:debug", "test:unit", "test:ui", "test:docs", "test:nested"}
SHA = "a" * 40
TESTED = "b" * 40


def gitlab(mrs=None, pipelines=None, diffs=(), jobs=None, fail=None):
    """A fake GitLab API: one merged MR !7 whose green pipeline 90 ran on TESTED."""
    mrs = [{"iid": 7, "state": "merged"}] if mrs is None else mrs
    pipelines = [{"id": 90, "status": "success", "sha": TESTED}] if pipelines is None else pipelines
    jobs = [{"name": n, "status": "success"} for n in MARKED] if jobs is None else jobs

    def api(path):
        if fail and fail in path:
            raise PLAN.ApiError(f"{fail}: 500")
        if path.endswith(f"repository/commits/{SHA}/merge_requests"):
            return mrs
        if path.endswith("merge_requests/7/pipelines"):
            return pipelines
        if "repository/compare" in path:
            return {"diffs": list(diffs)}
        if path.startswith("projects/5/pipelines/90/jobs"):
            return jobs
        raise AssertionError(f"unexpected API call {path}")

    return api


def ran_except(*skipped, failed=()):
    return ([{"name": n, "status": "success"} for n in sorted(MARKED - set(skipped) - set(failed))]
            + [{"name": n, "status": "failed"} for n in failed])


def plan(api, env=None):
    child, reason = PLAN.plan(yaml.safe_dump(MERGED), api, project="5", sha=SHA, env=env or {})
    return {k for k, v in child.items() if isinstance(v, dict) and not k.startswith(".")
            and k not in ("variables", "workflow", "default")}, child, reason


def test_every_marked_job_passed_on_the_same_tree_so_main_retests_nothing():
    jobs, child, reason = plan(gitlab())
    assert jobs == {"main-retest:nothing"}, jobs
    assert "!7" in reason and "pipeline 90" in reason


def test_a_job_the_mr_pipeline_skipped_by_path_is_retested():
    jobs, _, _ = plan(gitlab(jobs=ran_except("test:ui")))
    assert jobs == {"test:ui", "build:debug"}, jobs


def test_a_failed_or_allowed_to_fail_job_in_the_mr_is_not_covered():
    jobs, _, _ = plan(gitlab(jobs=ran_except(failed=("test:ui",))))
    assert "test:ui" in jobs


def test_a_retested_job_brings_the_jobs_it_needs():
    jobs, _, _ = plan(gitlab(jobs=ran_except("test:unit")))
    assert jobs == {"test:unit", "build:debug"}, jobs


# cli's test:unit has `needs: [{job: lint:format, optional: true}]`; an
# optional need on an unmarked job must not drag that job into the child.
def test_an_optional_need_on_an_unmarked_job_is_dropped_not_rerun():
    jobs, child, _ = plan(gitlab(jobs=ran_except("test:docs")))
    assert jobs == {"test:docs"}, jobs
    assert child["test:docs"]["needs"] == []


def test_marks_are_found_through_nested_rules_and_only_with_when_never():
    assert PLAN.marked_jobs(MERGED) == MARKED


def test_the_child_keeps_only_the_hidden_jobs_its_jobs_extend():
    _, child, _ = plan(gitlab(mrs=[]))
    assert ".runner" in child
    assert ".sast-analyzer" not in child and "sast" not in child


def test_no_merged_mr_retests_every_marked_job():
    jobs, _, reason = plan(gitlab(mrs=[]))
    assert jobs == MARKED, jobs
    assert "no merged MR" in reason


def test_a_green_pipeline_on_another_tree_covers_nothing():
    jobs, _, reason = plan(gitlab(diffs=[{"new_path": "src/lib.rs"}]))
    assert jobs == MARKED, jobs
    assert "same tree" in reason


def test_only_success_pipelines_count():
    jobs, _, _ = plan(gitlab(pipelines=[{"id": 90, "status": "failed", "sha": TESTED}]))
    assert jobs == MARKED, jobs


def test_an_api_error_retests_every_marked_job():
    jobs, _, reason = plan(gitlab(fail="compare"))
    assert jobs == MARKED, jobs
    assert "500" in reason


def test_the_child_keeps_hidden_jobs_and_settings_and_drops_unmarked_jobs():
    _, child, _ = plan(gitlab(mrs=[]))
    assert child[".runner"] == {"tags": ["docker"]}
    assert child["stages"] == STAGES
    assert child["variables"] == {"FOO": "1"}
    assert "github-mirror" not in child and "main:retest-plan" not in child and "lint:format" not in child
    assert child["workflow"] == {"rules": [{"when": "always"}]}


def test_a_retested_job_runs_in_the_child_whatever_its_rules_said():
    _, child, _ = plan(gitlab(mrs=[]))
    assert child["test:unit"]["rules"] == [{"when": "on_success"}]
    assert child["test:ui"]["allow_failure"] is True
    assert child["test:ui"]["needs"] == [{"job": "build:debug", "artifacts": True}]


# 2026-11-09, cli main 3044335259: the no-op job went to stages[0], .pre,
# and GitLab creates no pipeline whose only jobs are in .pre or .post.
def test_the_no_op_child_runs_in_a_real_stage_on_the_plan_jobs_runners():
    _, child, _ = plan(gitlab())
    job = child["main-retest:nothing"]
    assert job["stage"] == "build", job
    assert job["tags"] == ["docker"], job


def test_main_retest_off_runs_the_marked_jobs_in_main_so_the_child_is_empty():
    jobs, _, reason = plan(gitlab(), env={"MAIN_RETEST": "off"})
    assert jobs == {"main-retest:nothing"}, jobs
    assert "MAIN_RETEST=off" in reason


def test_the_templates_marker_rule_is_the_one_the_planner_finds():
    template = yaml.safe_load((MODULE_PATH.parents[1] / "ci-templates/main-retest.yml").read_text())
    rule = template[".main-retest"]["rules"][0]
    assert PLAN.MARKER in rule["if"] and rule["when"] == "never"
    assert rule["if"] == MARK["if"], "the fixture must mark jobs exactly as the template does"
    # Plan and trigger run only where marked jobs were held back.
    for job in (".main-retest-plan", ".main-retest-trigger"):
        assert template[job]["rules"] == [{"if": rule["if"]}], job
    assert template[".main-retest-trigger"]["trigger"]["strategy"] == "depend"


if __name__ == "__main__":
    for name, fn in list(globals().items()):
        if name.startswith("test_") and callable(fn):
            fn()
    print("main-retest-plan.test: PASS")
