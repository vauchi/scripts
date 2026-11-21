#!/usr/bin/env python3
# SPDX-FileCopyrightText: 2026 Mattia Egloff <mattia.egloff@pm.me>
# SPDX-License-Identifier: GPL-3.0-or-later
"""Stand-in for curl in script tests: every request gets the same answer.

FAKE_CURL_STATUS  HTTP status to answer with (default 200); "000" means the
                  connection failed, which real curl reports as exit 7.
FAKE_CURL_BODY    response body (default "[]").
FAKE_CURL_ROUTES  optional file of "<url fragment>\t<status>\t<body>" lines;
                  the first fragment found in the URL overrides the two above.
FAKE_CURL_LOG     optional file; each request appends "<METHOD> <URL>".

Mirrors the curl behaviour the VSH13 fixes rely on: -f drops the body on a
>= 400 status, --fail-with-body keeps it, both exit 22, and the
"(22) The requested URL returned error" line reaches stderr unless -s is
given without -S.
"""
import os
import sys

WITH_VALUE = {"-o", "--output", "-w", "--write-out", "-H", "--header", "-X",
              "--request", "-d", "--data", "--data-urlencode", "--max-time", "-m"}

args = sys.argv[1:]
output = write_out = None
method = "GET"
silent = show_error = fail = fail_with_body = False
url = ""
i = 0
while i < len(args):
    arg = args[i]
    if arg in WITH_VALUE:
        value = args[i + 1]
        if arg in ("-o", "--output"):
            output = value
        elif arg in ("-w", "--write-out"):
            write_out = value
        elif arg in ("-X", "--request"):
            method = value
        elif arg.startswith("--data") or arg == "-d":
            method = "POST" if method == "GET" else method
        i += 2
        continue
    if arg == "--silent":
        silent = True
    elif arg == "--show-error":
        show_error = True
    elif arg == "--fail":
        fail = True
    elif arg == "--fail-with-body":
        fail_with_body = True
    elif arg.startswith("-") and not arg.startswith("--"):
        silent |= "s" in arg
        show_error |= "S" in arg
        fail |= "f" in arg
    elif not arg.startswith("-"):
        url = arg
    i += 1

status = os.environ.get("FAKE_CURL_STATUS", "200")
body = os.environ.get("FAKE_CURL_BODY", "[]")
if os.environ.get("FAKE_CURL_ROUTES"):
    with open(os.environ["FAKE_CURL_ROUTES"], encoding="utf-8") as routes:
        for route in routes:
            fragment, route_status, route_body = route.rstrip("\n").split("\t", 2)
            if fragment in url:
                status, body = route_status, route_body
                break
if os.environ.get("FAKE_CURL_LOG"):
    with open(os.environ["FAKE_CURL_LOG"], "a", encoding="utf-8") as log:
        log.write(f"{method} {url}\n")

if status == "000":
    if write_out:
        sys.stdout.write(write_out.replace("%{http_code}", "000"))
    if show_error or not silent:
        sys.stderr.write(f"curl: (7) Failed to connect to {url}\n")
    sys.exit(7)

failing = int(status) >= 400 and (fail or fail_with_body)
if not (failing and not fail_with_body):
    if output:
        with open(output, "w", encoding="utf-8") as handle:
            handle.write(body)
    else:
        sys.stdout.write(body)
if write_out:
    sys.stdout.write(write_out.replace("%{http_code}", status))
if failing:
    if show_error or not silent:
        sys.stderr.write(f"curl: (22) The requested URL returned error: {status}\n")
    sys.exit(22)
