#!/usr/bin/env python3
# SPDX-FileCopyrightText: 2026 Mattia Egloff <mattia.egloff@pm.me>
#
# SPDX-License-Identifier: GPL-3.0-or-later

"""Write main's child pipeline: the marked jobs no MR pipeline proved on this tree.

A job marked with `.main-retest` (ci-templates/main-retest.yml) does not run
in a push pipeline on main. This planner finds the merged MR for the main
commit, that MR's newest green pipeline whose commit has the same tree, and
the jobs that succeeded there. The marked jobs not among them, with the jobs
they need, run in the child; anything in doubt retests every marked job
(vauchi/private#1179, decision 8).

Usage (CI): main-retest-plan.py <out.yml>
Env: CI_API_V4_URL, CI_PROJECT_ID, CI_COMMIT_SHA, PROJECT_ACCESS_TOKEN,
     CI_CONFIG_PATH (default .gitlab-ci.yml), MAIN_RETEST
"""

import json
import os
import sys
import urllib.error
import urllib.parse
import urllib.request

import yaml

MARKER = "$MAIN_RETEST"
NOTHING = "main-retest:nothing"
NOT_JOBS = {"stages", "variables", "workflow", "default", "include", "image", "services",
            "before_script", "after_script", "cache"}


class ApiError(Exception):
    pass


def visible_jobs(config):
    return {k: v for k, v in config.items()
            if isinstance(v, dict) and not k.startswith(".") and k not in NOT_JOBS}


def marked_jobs(config):
    return {name for name, job in visible_jobs(config).items()
            if any(isinstance(r, dict) and MARKER in str(r.get("if", "")) for r in job.get("rules", []))}


def needed(job):
    for need in job.get("needs", []) or []:
        yield need["job"] if isinstance(need, dict) else need


def close_over_needs(config, names):
    jobs = visible_jobs(config)
    todo, seen = list(names), set()
    while todo:
        name = todo.pop()
        if name in seen or name not in jobs:
            continue
        seen.add(name)
        todo.extend(needed(jobs[name]))
    return seen


def covered_jobs(api, project, sha):
    """Job names that succeeded in an MR pipeline on this commit's tree, and why."""
    mrs = [m for m in api(f"projects/{project}/repository/commits/{sha}/merge_requests")
           if m.get("state") == "merged"]
    if not mrs:
        return set(), f"no merged MR for {sha[:8]}: every marked job runs"
    iid = mrs[0]["iid"]
    for pipeline in api(f"projects/{project}/merge_requests/{iid}/pipelines"):
        if pipeline.get("status") != "success":
            continue
        compare = api(f"projects/{project}/repository/compare?from={pipeline['sha']}&to={sha}&straight=true")
        if compare.get("diffs"):
            continue
        jobs = api(f"projects/{project}/pipelines/{pipeline['id']}/jobs?per_page=100&scope[]=success")
        names = {j["name"] for j in jobs if j.get("status") == "success"}
        return names, f"!{iid} pipeline {pipeline['id']} passed on the same tree"
    return set(), f"!{iid} has no green pipeline on the same tree: every marked job runs"


def child_config(config, retest):
    child = {k: v for k, v in config.items() if not isinstance(v, dict) or k.startswith(".")
             or k in NOT_JOBS}
    child.pop("include", None)
    child["workflow"] = {"rules": [{"when": "always"}]}
    if not retest:
        stage = (config.get("stages") or ["test"])[0]
        child[NOTHING] = {"stage": stage, "image": "alpine:3.21", "script": ["echo every marked job passed on this tree"]}
        return child
    for name in sorted(retest):
        job = dict(config[name])
        # The child runs exactly what the planner chose; the job's own rules
        # were written for MR and push pipelines, not a parent_pipeline.
        job["rules"] = [{"when": "on_success"}]
        child[name] = job
    return child


def plan(merged_yaml, api, project, sha, env):
    config = yaml.safe_load(merged_yaml)
    if env.get("MAIN_RETEST") == "off":
        return child_config(config, set()), "MAIN_RETEST=off: the marked jobs ran in main itself"
    marked = marked_jobs(config)
    try:
        covered, reason = covered_jobs(api, project, sha)
    except ApiError as error:
        covered, reason = set(), f"GitLab API error ({error}): every marked job runs"
    retest = close_over_needs(config, marked - covered)
    return child_config(config, retest), reason


def gitlab_api(base, token):
    def api(path):
        request = urllib.request.Request(f"{base}/{path}", headers={"PRIVATE-TOKEN": token})
        try:
            with urllib.request.urlopen(request, timeout=30) as response:
                return json.load(response)
        except (urllib.error.URLError, TimeoutError, ValueError) as error:
            raise ApiError(f"{path.split('?')[0]}: {error}") from error
    return api


def merged_yaml(base, token, project, config_path):
    body = urllib.parse.urlencode({"content": open(config_path).read(), "include_merged_yaml": "true"}).encode()
    request = urllib.request.Request(f"{base}/projects/{project}/ci/lint", data=body,
                                     headers={"PRIVATE-TOKEN": token})
    with urllib.request.urlopen(request, timeout=60) as response:
        result = json.load(response)
    if not result.get("valid") or not result.get("merged_yaml"):
        raise ApiError(f"ci/lint: {result.get('errors')}")
    return result["merged_yaml"]


def main(argv):
    out = argv[1]
    env = os.environ
    base, token, project = env["CI_API_V4_URL"], env["PROJECT_ACCESS_TOKEN"], env["CI_PROJECT_ID"]
    # Without the merged YAML there is no child to write: fail the job, so
    # main is red rather than silently untested.
    text = merged_yaml(base, token, project, env.get("CI_CONFIG_PATH") or ".gitlab-ci.yml")
    child, reason = plan(text, gitlab_api(base, token), project, env["CI_COMMIT_SHA"], env)
    with open(out, "w") as stream:
        yaml.safe_dump(child, stream, sort_keys=False)
    jobs = sorted(k for k in visible_jobs(child))
    print(f"main-retest: {reason}")
    print(f"main-retest: child runs {', '.join(jobs)}")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
