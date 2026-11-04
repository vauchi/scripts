#!/usr/bin/env python3
# SPDX-FileCopyrightText: 2026 Mattia Egloff <mattia.egloff@pm.me>
# SPDX-License-Identifier: GPL-3.0-or-later
"""Create a Vauchi project and verify its merge and main-branch policy."""

import argparse
import fnmatch
import json
import re
import subprocess
import sys
from urllib.parse import quote

SETTINGS = {
    "default_branch": "main", "merge_method": "ff", "squash_option": "never",
    "merge_pipelines_enabled": True, "merge_trains_enabled": False,
    "shared_runners_enabled": False, "auto_devops_enabled": False,
    "only_allow_merge_if_pipeline_succeeds": True,
    "only_allow_merge_if_all_discussions_are_resolved": True,
}


class ApiError(RuntimeError):
    def __init__(self, message, status=None):
        super().__init__(message)
        self.status = status


def request(method, endpoint, fields=None):
    args = ["glab", "api", "--hostname", "gitlab.com", "--include",
            "--method", method, endpoint]
    if fields is not None:
        args.extend(["--input", "-"])
    try:
        response = subprocess.run(
            args, input=json.dumps(fields) if fields is not None else None,
            capture_output=True, text=True, check=False, timeout=60,
        )
    except (OSError, subprocess.TimeoutExpired, UnicodeError) as error:
        raise ApiError(f"GitLab API {method} {endpoint}: transport failed") from error
    headers, separator, body = response.stdout.replace("\r\n", "\n").partition("\n\n")
    match = re.match(r"HTTP/\S+\s+(\d{3})\b", headers)
    if not match or not separator:
        raise ApiError(f"GitLab API {method} {endpoint}: no HTTP status received")
    status = int(match[1])
    if response.returncode or not 200 <= status < 300:
        raise ApiError(f"GitLab API {method} {endpoint}: HTTP {status}", status)
    try:
        result = json.loads(body)
    except (ValueError, TypeError) as error:
        raise ApiError(f"GitLab API {method} {endpoint}: invalid JSON", status) from error
    if not isinstance(result, (dict, list)):
        raise ApiError(f"GitLab API {method} {endpoint}: invalid JSON shape", status)
    return result


def positive_id(value):
    return type(value) is int and value > 0


def verify_identity(project, name):
    if not isinstance(project, dict) or not positive_id(project.get("id")):
        raise ApiError("Invalid project identity in GitLab response")
    if project.get("path_with_namespace") != f"vauchi/{name}":
        raise ApiError("Unexpected project namespace/path in GitLab response")


def verify_settings(project, visibility):
    for key, expected in {**SETTINGS, "visibility": visibility}.items():
        actual = project.get(key)
        if type(actual) is not type(expected) or actual != expected:
            raise ApiError(f"Project setting {key} does not match required value {expected!r}")


def roles_safe(entries, push=False):
    if not isinstance(entries, list) or not entries:
        return False
    for entry in entries:
        if not isinstance(entry, dict):
            return False
        if any(entry.get(key) is not None for key in
               ("user_id", "group_id", "deploy_key_id", "member_role_id")):
            return False
        level = entry.get("access_level")
        if type(level) is not int or (level != 0 and (push or level < 40)):
            return False
    return push or any(entry["access_level"] >= 40 for entry in entries)


def protection_safe(rule, require_owner=False):
    return (
        isinstance(rule, dict)
        and rule.get("allow_force_push") is False
        and (not require_owner or rule.get("code_owner_approval_required") is True)
        and roles_safe(rule.get("push_access_levels"), push=True)
        and roles_safe(rule.get("merge_access_levels"))
    )


def replacement_levels(entries, access_level):
    if not isinstance(entries, list) or any(
        not isinstance(entry, dict) or not positive_id(entry.get("id")) for entry in entries
    ):
        raise ApiError("Invalid protection access-level IDs; no rule was changed")
    return [{"id": entry["id"], "_destroy": True} for entry in entries] + [
        {"access_level": access_level}
    ]


def ensure_protection(api, endpoint, created):
    branch_endpoint = f"{endpoint}/protected_branches/main"
    try:
        rule = api("GET", branch_endpoint)
    except ApiError as error:
        if error.status != 404:
            raise
        if not created:
            raise ApiError("Existing project is missing main protection; left unchanged") from error
        rule = api("POST", f"{endpoint}/protected_branches", {
            "name": "main", "push_access_level": 0, "merge_access_level": 40,
            "allow_force_push": False, "code_owner_approval_required": True,
        })
    if not protection_safe(rule, require_owner=True):
        if not created or not isinstance(rule, dict) or rule.get("inherited") is not False:
            raise ApiError("Unsafe main protection; existing or inherited rule left unchanged")
        api("PATCH", branch_endpoint, {
            "allowed_to_push": replacement_levels(rule.get("push_access_levels"), 0),
            "allowed_to_merge": replacement_levels(rule.get("merge_access_levels"), 40),
            "allow_force_push": False, "code_owner_approval_required": True,
        })
    rule = api("GET", branch_endpoint)
    if not protection_safe(rule, require_owner=True):
        raise ApiError("main protection does not match the required policy")
    rules = api("GET", f"{endpoint}/protected_branches?per_page=100")
    if not isinstance(rules, list) or len(rules) >= 100:
        raise ApiError("Cannot verify all protection rules; manual review required")
    for other in rules:
        if not isinstance(other, dict) or not isinstance(other.get("name"), str):
            raise ApiError("Invalid protection rule response")
        if fnmatch.fnmatchcase("main", other["name"]) and not protection_safe(other):
            raise ApiError(f"Matching protection rule {other['name']!r} allows unsafe access")


def provision(name, description="", visibility="public", api=request):
    if len(name) > 100 or not re.fullmatch(r"[a-z0-9]+(?:-[a-z0-9]+)*", name):
        raise ApiError("Repository name must be 1–100 lowercase letters, digits or separated hyphens")
    if visibility not in ("public", "private") or len(description) > 2000:
        raise ApiError("Invalid visibility or description longer than 2000 characters")
    endpoint = "projects/" + quote(f"vauchi/{name}", safe="")
    created = False
    try:
        project = api("GET", endpoint)
    except ApiError as error:
        if error.status != 404:
            raise
        group = api("GET", "groups/vauchi")
        if not isinstance(group, dict) or not positive_id(group.get("id")):
            raise ApiError("Invalid Vauchi namespace response")
        project = api("POST", "projects", {
            "namespace_id": group["id"], "name": name, "path": name,
            "description": description, "visibility": visibility,
            "default_branch": "main", "initialize_with_readme": True,
        })
        verify_identity(project, name)
        created = True
        # Creation accepted but ignored merged-results pipelines in GitLab.
        api("PUT", endpoint, {**SETTINGS, "visibility": visibility})
        project = api("GET", endpoint)
    verify_identity(project, name)
    verify_settings(project, visibility)
    ensure_protection(api, endpoint, created)
    return project


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("name")
    parser.add_argument("--description", default="")
    parser.add_argument("--visibility", choices=("public", "private"), default="public")
    args = parser.parse_args()
    try:
        project = provision(args.name, args.description, args.visibility)
    except ApiError as error:
        print(f"ERROR: {error}. No project is automatically deleted; inspect before retrying.", file=sys.stderr)
        return 1
    print(f"Verified https://gitlab.com/{project['path_with_namespace']}: merge policy and main protection")
    return 0


if __name__ == "__main__":
    sys.exit(main())
