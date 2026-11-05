#!/usr/bin/env python3
# SPDX-FileCopyrightText: 2026 Mattia Egloff <mattia.egloff@pm.me>
# SPDX-License-Identifier: GPL-3.0-or-later
"""Provisioning contract for the developer workflow in issue 1075."""

import copy
import importlib.util
import json
import subprocess
import unittest
from pathlib import Path
from unittest import mock

SPEC = importlib.util.spec_from_file_location(
    "create_repo", Path(__file__).resolve().parents[1] / "create-repo.py"
)
repo = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(repo)

SETTINGS = {
    "default_branch": "main", "visibility": "public", "merge_method": "ff",
    "squash_option": "never", "merge_pipelines_enabled": True,
    "merge_trains_enabled": False, "shared_runners_enabled": False,
    "auto_devops_enabled": False, "only_allow_merge_if_pipeline_succeeds": True,
    "only_allow_merge_if_all_discussions_are_resolved": True,
}


def protection(name="main", push=0):
    return {
        "name": name, "push_access_levels": [{"id": 1, "access_level": push}],
        "merge_access_levels": [{"id": 2, "access_level": 40}],
        "allow_force_push": False, "code_owner_approval_required": True,
        "inherited": False,
    }


class GitLab:
    def __init__(self, existing=False):
        self.project = {
            "id": 123, "path_with_namespace": "vauchi/apple-display",
            **SETTINGS,
        } if existing else None
        self.rules = [protection()] if existing else []
        self.writes = []
        self.ignore_update = False
        self.failed_method = None
        self.default_protection = None
        self.ignore_approval_update = False
        self.approvals = ([{"id": 9, "name": "All Members", "rule_type": "any_approver",
                            "approvals_required": 1, "protected_branches": [],
                            "applies_to_all_protected_branches": False}] if existing else [])

    def __call__(self, method, endpoint, fields=None):
        if method == self.failed_method:
            raise repo.ApiError("forbidden", 403)
        if method != "GET":
            self.writes.append((method, endpoint, copy.deepcopy(fields)))
        if endpoint == "groups/vauchi":
            return {"id": 122552022}
        if endpoint == "projects" and method == "POST":
            self.project = {
                "id": 123, "path_with_namespace": "vauchi/apple-display",
                **SETTINGS, "merge_pipelines_enabled": False,
            }
            if self.default_protection:
                self.rules = [copy.deepcopy(self.default_protection)]
            return copy.deepcopy(self.project)
        if "/approval_rules" in endpoint:
            if method == "POST":
                self.approvals = [{"id": 9, "protected_branches": [],
                                   "applies_to_all_protected_branches": False, **fields}]
                return copy.deepcopy(self.approvals[0])
            if method == "PUT" and not self.ignore_approval_update:
                self.approvals[0].update(fields)
                return copy.deepcopy(self.approvals[0])
            return copy.deepcopy(self.approvals)
        if "/protected_branches" in endpoint:
            if method == "POST":
                self.rules.append(protection())
                return copy.deepcopy(self.rules[-1])
            if method == "PATCH":
                self.rules[0] = protection()
                return copy.deepcopy(self.rules[0])
            if endpoint.endswith("/main"):
                for rule in self.rules:
                    if rule["name"] == "main":
                        return copy.deepcopy(rule)
                raise repo.ApiError("not found", 404)
            return copy.deepcopy(self.rules)
        if self.project is None:
            raise repo.ApiError("not found", 404)
        if method == "PUT" and not self.ignore_update:
            self.project.update(fields)
        return copy.deepcopy(self.project)


class ProvisionTests(unittest.TestCase):
    def test_new_project_requires_member_approval_like_reference_repo(self):
        api = GitLab()
        repo.provision("apple-display", api=api)
        self.assertEqual([(r["name"], r["rule_type"], r["approvals_required"])
                          for r in api.approvals], [("All Members", "any_approver", 1)])

    def test_existing_project_without_required_approval_is_read_only_failure(self):
        api = GitLab(existing=True)
        api.approvals = []
        with self.assertRaisesRegex(repo.ApiError, "approval"):
            repo.provision("apple-display", api=api)
        self.assertEqual(api.writes, [])

    def test_zero_approval_default_is_raised_for_new_project(self):
        api = GitLab(existing=True)
        api.project = None
        api.approvals[0]["approvals_required"] = 0
        repo.provision("apple-display", api=api)
        self.assertEqual(api.approvals[0]["approvals_required"], 1)

    def test_stronger_existing_approval_is_preserved(self):
        api = GitLab(existing=True)
        api.approvals[0]["approvals_required"] = 2
        self.assertEqual(repo.provision("apple-display", api=api)["id"], 123)
        self.assertEqual(api.approvals[0]["approvals_required"], 2)
        self.assertEqual(api.writes, [])

    def test_approval_for_another_branch_does_not_cover_main(self):
        api = GitLab(existing=True)
        api.approvals[0]["protected_branches"] = [{"name": "release"}]
        with self.assertRaisesRegex(repo.ApiError, "approval"):
            repo.provision("apple-display", api=api)
        self.assertEqual(api.writes, [])

    def test_wildcard_approval_covering_main_is_preserved_without_writes(self):
        for pattern in ("*", "ma*"):
            with self.subTest(pattern=pattern):
                api = GitLab(existing=True)
                api.approvals[0]["protected_branches"] = [{"name": pattern}]
                self.assertEqual(repo.provision("apple-display", api=api)["id"], 123)
                self.assertEqual(api.writes, [])

    def test_ignored_approval_update_cannot_report_success(self):
        api = GitLab(existing=True)
        api.project = None
        api.approvals[0]["approvals_required"] = 0
        api.ignore_approval_update = True
        with self.assertRaisesRegex(repo.ApiError, "approval"):
            repo.provision("apple-display", api=api)

    def test_creation_reconciles_ignored_flag_and_protects_main(self):
        api = GitLab()
        result = repo.provision("apple-display", api=api)
        self.assertEqual(result["path_with_namespace"], "vauchi/apple-display")
        self.assertEqual({k: api.project[k] for k in SETTINGS}, SETTINGS)
        self.assertEqual(api.rules, [protection()])
        create = next(fields for method, path, fields in api.writes if path == "projects")
        self.assertEqual(create["namespace_id"], 122552022)
        self.assertEqual(create["initialize_with_readme"], True)
        self.assertIn("PUT", [method for method, _, _ in api.writes])

    def test_existing_compliant_project_is_verified_without_writes(self):
        api = GitLab(existing=True)
        self.assertEqual(repo.provision("apple-display", api=api)["id"], 123)
        self.assertEqual(api.writes, [])

    def test_existing_unsafe_settings_are_not_silently_rewritten(self):
        api = GitLab(existing=True)
        api.project["merge_pipelines_enabled"] = False
        with self.assertRaisesRegex(repo.ApiError, "merge_pipelines_enabled"):
            repo.provision("apple-display", api=api)
        self.assertEqual(api.writes, [])

    def test_hidden_settings_require_maintainer_visibility(self):
        api = GitLab(existing=True)
        del api.project["auto_devops_enabled"]
        with self.assertRaisesRegex(repo.ApiError, "Maintainer"):
            repo.provision("apple-display", api=api)
        self.assertEqual(api.writes, [])

    def test_existing_unprotected_main_is_rejected_without_mutation(self):
        api = GitLab(existing=True)
        api.rules = []
        with self.assertRaisesRegex(repo.ApiError, "main"):
            repo.provision("apple-display", api=api)
        self.assertEqual(api.writes, [])

    def test_default_main_rule_is_corrected_without_unprotecting(self):
        api = GitLab()
        api.default_protection = protection(push=40)
        repo.provision("apple-display", api=api)
        self.assertEqual(api.rules, [protection()])
        methods = [m for m, _, _ in api.writes]
        self.assertIn("PATCH", methods)
        self.assertNotIn("DELETE", methods)

    def test_server_ignoring_update_prevents_success(self):
        api = GitLab()
        api.ignore_update = True
        with self.assertRaisesRegex(repo.ApiError, "merge_pipelines_enabled"):
            repo.provision("apple-display", api=api)

    def test_permissive_wildcard_is_not_hidden_by_exact_main_rule(self):
        api = GitLab(existing=True)
        api.rules.append(protection("*", push=40))
        with self.assertRaisesRegex(repo.ApiError, "protection"):
            repo.provision("apple-display", api=api)
        self.assertEqual(api.writes, [])

    def test_more_restrictive_wildcard_does_not_block_safe_main(self):
        api = GitLab(existing=True)
        rule = protection("*")
        rule["merge_access_levels"] = [{"access_level": 0}]
        rule["code_owner_approval_required"] = False
        api.rules.append(rule)
        self.assertEqual(repo.provision("apple-display", api=api)["id"], 123)
        self.assertEqual(api.writes, [])

    def test_force_push_or_direct_user_grant_is_rejected(self):
        for change in [
            {"allow_force_push": True},
            {"push_access_levels": [{"user_id": 7, "access_level": None}]},
            {"merge_access_levels": [{"access_level": 30}]},
            {"merge_access_levels": [{"access_level": 1000}]},
            {"code_owner_approval_required": False},
        ]:
            with self.subTest(change=change):
                api = GitLab(existing=True)
                api.rules[0].update(change)
                with self.assertRaisesRegex(repo.ApiError, "protection"):
                    repo.provision("apple-display", api=api)
                self.assertEqual(api.writes, [])

    def test_invalid_names_fail_before_any_api_call(self):
        for name in ["", "../core", "-bad", "a/b", "a\nb", "$(id)", "x" * 101]:
            with self.subTest(name=name):
                api = mock.Mock()
                with self.assertRaisesRegex(repo.ApiError, "name"):
                    repo.provision(name, api=api)
                api.assert_not_called()

    def test_wrong_project_response_is_not_trusted(self):
        api = GitLab(existing=True)
        api.project["path_with_namespace"] = "other/apple-display"
        with self.assertRaisesRegex(repo.ApiError, "project"):
            repo.provision("apple-display", api=api)
        self.assertEqual(api.writes, [])

    def test_authorization_failure_does_not_trigger_creation(self):
        api = GitLab()
        api.failed_method = "GET"
        with self.assertRaises(repo.ApiError) as caught:
            repo.provision("apple-display", api=api)
        self.assertEqual(caught.exception.status, 403)
        self.assertEqual(api.writes, [])

    def test_permission_failure_after_creation_does_not_delete_project(self):
        api = GitLab()
        api.failed_method = "PUT"
        with self.assertRaises(repo.ApiError) as caught:
            repo.provision("apple-display", api=api)
        self.assertEqual(caught.exception.status, 403)
        self.assertEqual(api.project["id"], 123)
        self.assertNotIn("DELETE", [m for m, _, _ in api.writes])


class TransportTests(unittest.TestCase):
    def run_response(self, stdout, returncode=0):
        return subprocess.CompletedProcess([], returncode, stdout, "sensitive detail")

    def test_http_failure_is_detected_before_parsing_json(self):
        response = self.run_response("HTTP/2.0 403 Forbidden\n\nnot json", 1)
        with mock.patch.object(repo.subprocess, "run", return_value=response):
            with self.assertRaises(repo.ApiError) as caught:
                repo.request("GET", "groups/vauchi")
        self.assertEqual(caught.exception.status, 403)
        self.assertNotIn("sensitive detail", str(caught.exception))

    def test_success_with_malformed_json_is_rejected(self):
        response = self.run_response("HTTP/2.0 200 OK\n\nnot json")
        with mock.patch.object(repo.subprocess, "run", return_value=response):
            with self.assertRaisesRegex(repo.ApiError, "JSON"):
                repo.request("GET", "groups/vauchi")

    def test_json_fields_use_argv_without_shell_interpolation(self):
        response = self.run_response('HTTP/2.0 200 OK\n\n{"id": 12}')
        description = 'A "quote" and $(do-not-run)'
        with mock.patch.object(repo.subprocess, "run", return_value=response) as run:
            self.assertEqual(repo.request("POST", "projects", {"description": description}), {"id": 12})
        self.assertIn("--input", run.call_args.args[0])
        self.assertEqual(json.loads(run.call_args.kwargs["input"]), {"description": description})
        self.assertFalse(run.call_args.kwargs.get("shell", False))


if __name__ == "__main__":
    unittest.main()
