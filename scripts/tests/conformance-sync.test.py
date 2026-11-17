#!/usr/bin/env python3
# SPDX-FileCopyrightText: 2026 Mattia Egloff <mattia.egloff@pm.me>
#
# SPDX-License-Identifier: GPL-3.0-or-later

import importlib.util
import io
import os
import sys
import unittest
import urllib.error
import urllib.parse
from pathlib import Path
from unittest.mock import patch

MODULE_PATH = Path(__file__).resolve().parents[1] / "check-conformance-sync.py"
SPEC = importlib.util.spec_from_file_location("check_conformance_sync", MODULE_PATH)
assert SPEC and SPEC.loader
SYNC = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(SYNC)


class ConformanceSyncTests(unittest.TestCase):
    def run_api(self, urlopen):
        environment = {
            "CI_API_V4_URL": "https://gitlab.example/api/v4",
            "CI_JOB_TOKEN": "test-token",
            "CONFORMANCE_OWN_REF": "pin-only",
        }
        with patch.dict(os.environ, environment, clear=True), \
                patch.object(sys, "argv", ["check-conformance-sync.py", "--api"]), \
                patch.object(SYNC.urllib.request, "urlopen", side_effect=urlopen):
            return SYNC.main()

    @staticmethod
    def project_and_ref(url):
        parsed = urllib.parse.urlparse(url)
        project_id = parsed.path.split("/")[4]
        projects = {str(value): key for key, value in SYNC.PROJECT_IDS.items()}
        if "/repository/branches/" in parsed.path:
            ref = urllib.parse.unquote(parsed.path.split("/repository/branches/")[1])
        else:
            ref = urllib.parse.parse_qs(parsed.query)["ref"][0]
        return projects[project_id], ref

    def test_missing_peer_branch_reads_the_peer_file_from_main(self):
        file_requests = []

        def respond(request, timeout):
            self.assertEqual(timeout, 30)
            project, ref = self.project_and_ref(request.full_url)
            if "/repository/branches/" in request.full_url:
                if project != "core" and ref == "pin-only":
                    raise urllib.error.HTTPError(request.full_url, 404, "missing", None, None)
                return io.BytesIO(b"{}")
            file_requests.append((project, ref))
            if project != "core" and ref == "pin-only":
                raise urllib.error.HTTPError(request.full_url, 404, "missing", None, None)
            return io.BytesIO(b"same normalized suite\n")

        self.assertEqual(self.run_api(respond), 0)
        self.assertIn(("linux-hw", "main"), file_requests)
        self.assertIn(("contract", "main"), file_requests)
        self.assertNotIn(("linux-hw", "pin-only"), file_requests)
        self.assertNotIn(("contract", "pin-only"), file_requests)

    def test_existing_peer_branch_does_not_fallback_when_its_file_is_missing(self):
        file_requests = []

        def respond(request, timeout):
            project, ref = self.project_and_ref(request.full_url)
            if "/repository/branches/" in request.full_url:
                return io.BytesIO(b"{}")
            file_requests.append((project, ref))
            if project == "linux-hw" and ref == "pin-only":
                raise urllib.error.HTTPError(request.full_url, 404, "missing", None, None)
            return io.BytesIO(b"same normalized suite\n")

        self.assertEqual(self.run_api(respond), 2)
        self.assertNotIn(("linux-hw", "main"), file_requests)

    def test_branch_lookup_server_error_is_not_treated_as_a_missing_branch(self):
        def respond(request, timeout):
            project, ref = self.project_and_ref(request.full_url)
            if "/repository/branches/" in request.full_url and project == "linux-hw":
                raise urllib.error.HTTPError(request.full_url, 500, "unavailable", None, None)
            return io.BytesIO(b"same normalized suite\n")

        self.assertEqual(self.run_api(respond), 2)


if __name__ == "__main__":
    unittest.main()
