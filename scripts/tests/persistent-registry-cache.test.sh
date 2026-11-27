#!/usr/bin/env bash
# SPDX-FileCopyrightText: 2026 Mattia Egloff <mattia.egloff@pm.me>
# SPDX-License-Identifier: GPL-3.0-or-later
set -euo pipefail
root=$(cd "$(dirname "$0")/../.." && pwd)
python3 - "$root/ci-templates/rust-base.yml" <<'PYTHON'
import hashlib
import sys
import yaml

template = yaml.load(open(sys.argv[1]), Loader=yaml.BaseLoader)
failures = []

def check(ok, message):
    print(('PASS ' if ok else 'FAIL ') + message)
    if not ok:
        failures.append(message)

def cache_key(cache, project, lock):
    key = cache['key']
    if isinstance(key, dict):
        prefix = key.get('prefix', '')
        suffix = hashlib.sha256(lock.encode()).hexdigest() if key.get('files') else ''
        key = prefix + suffix
    return key.replace('${CI_PROJECT_NAME}', project)

for name in ('.linux-runner', '.linux-runner-readonly', '.rust-runner',
             '.rust-runner-readonly', '.macos-runner'):
    cache = template[name]['cache']
    first = cache_key(cache, 'core', 'lock revision one')
    second = cache_key(cache, 'core', 'lock revision two')
    check(first == second, name + ': lock updates reuse the download archive')
    check(first != cache_key(cache, 'e2e', 'lock revision one'),
          name + ': projects remain separate')
    check(cache.get('unprotect') != 'true', name + ': protection boundary remains')
    paths = cache['paths']
    check(set(paths) == {'.cargo/registry/index/', '.cargo/registry/cache/', '.cargo/git/db/'},
          name + ': only architecture-neutral download inputs are archived')
    check(cache['policy'] == ('pull' if 'readonly' in name else 'pull-push'),
          name + ': existing read/write policy remains')
sys.exit(bool(failures))
PYTHON
