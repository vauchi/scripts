#!/usr/bin/env bash
# SPDX-FileCopyrightText: 2026 Mattia Egloff <mattia.egloff@pm.me>
#
# SPDX-License-Identifier: GPL-3.0-or-later

# Regression suite for ci/vrt-approve.sh (vauchi/private#836).
#
# The VRT API is replaced by a `curl` stub on PATH that answers each
# endpoint from fixture variables and logs every call, so the suite runs
# without credentials or network.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT="$SCRIPT_DIR/../ci/vrt-approve.sh"

pass=0
fail=0

check() {
    local name="$1"
    shift
    if "$@"; then
        printf '  PASS %s\n' "$name"
        pass=$((pass + 1))
    else
        printf '  FAIL %s\n' "$name" >&2
        fail=$((fail + 1))
    fi
}

WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT
mkdir -p "$WORK/bin"

# Stub curl: finds the URL and -o target among its arguments, writes the
# fixture body for that endpoint, prints the fixture status for -w, and
# logs method, URL and Authorization header.
cat > "$WORK/bin/curl" <<'STUB'
#!/usr/bin/env bash
out="" url="" method="GET" auth="" body=""
while [ $# -gt 0 ]; do
    case "$1" in
        -o) out="$2"; shift ;;
        -X) method="$2"; shift ;;
        -H) case "$2" in Authorization:*) auth="$2" ;; esac; shift ;;
        -d|--data|--data-raw) body="$2"; shift ;;
        -w|--max-time) shift ;;
        http*) url="$1" ;;
    esac
    shift
done
printf '%s %s | %s | %s\n' "$method" "$url" "$auth" "$body" >> "$STUB_LOG"
case "$url" in
    */users/login)            code="$LOGIN_CODE";    resp="$LOGIN_BODY" ;;
    */projects)               code="$PROJECTS_CODE"; resp="$PROJECTS_BODY" ;;
    */builds\?*)              code="$BUILDS_CODE";   resp="$BUILDS_BODY" ;;
    */builds/*/approve\?*)    code="$APPROVE_CODE";  resp="{}" ;;
    *)                        code="404";            resp="{}" ;;
esac
[ -n "$out" ] && printf '%s' "$resp" > "$out"
printf '%s' "$code"
STUB
chmod +x "$WORK/bin/curl"

# Defaults describe the happy path; each case overrides what it breaks.
reset_fixture() {
    export STUB_LOG="$WORK/calls.log"
    : > "$STUB_LOG"
    export LOGIN_CODE=201 LOGIN_BODY='{"token":"tok-123"}'
    export PROJECTS_CODE=200 PROJECTS_BODY='[{"id":"p-other","name":"other"},{"id":"11111111-1111-1111-1111-111111111111","name":"vauchi"}]'
    export BUILDS_CODE=200 BUILDS_BODY='{"data":[{"id":"22222222-2222-2222-2222-222222222222","ciBuildId":"777-macos"}],"total":1}'
    export APPROVE_CODE=200
}

run_script() {
    PATH="$WORK/bin:$PATH" \
    VRT_API_URL=https://vrt.test \
    VRT_PROJECT=vauchi \
    VRT_PLATFORM=macos \
    CI_PIPELINE_ID=777 \
    VRT_RECORDER_EMAIL="${VRT_RECORDER_EMAIL-ci-recorder@vauchi.test}" \
    VRT_RECORDER_PASSWORD="${VRT_RECORDER_PASSWORD-s3cret-pw}" \
    sh "$SCRIPT" > "$WORK/out.log" 2>&1
}

log_has() { grep -qF -- "$1" "$STUB_LOG"; }
out_has() { grep -qF -- "$1" "$WORK/out.log"; }
not() { ! "$@"; }

echo "vrt-approve.sh"

# 1. Happy path: login, project, build, approve — in that order.
reset_fixture
check "happy path exits 0" run_script
check "logs in with the recorder's email" log_has '/users/login'
check "looks the build up by this pipeline's ciBuildId" log_has 'ciBuildId=777-macos'
check "looks the build up in the vauchi project" log_has 'projectId=11111111-1111-1111-1111-111111111111'
check "approves that build without merging" log_has 'PATCH https://vrt.test/builds/22222222-2222-2222-2222-222222222222/approve?merge=false'
check "authenticates with the login token" log_has 'Authorization: Bearer tok-123'
check "calls happen in order" test "$(cut -d' ' -f2 "$STUB_LOG" | sed 's|https://vrt.test||; s|?.*||' | tr '\n' ' ')" = "/users/login /projects /builds /builds/22222222-2222-2222-2222-222222222222/approve "
check "never prints the password" not out_has 's3cret-pw'
check "never prints the token" not out_has 'tok-123'

# 2. Missing credentials fail loudly: a deliberate record run must not pass silently.
reset_fixture
export VRT_RECORDER_PASSWORD=
check "missing password exits non-zero" not run_script
check "names the missing variable" out_has 'VRT_RECORDER_PASSWORD'
check "makes no API call without credentials" test ! -s "$STUB_LOG"
unset VRT_RECORDER_PASSWORD

# 3. A refused login fails and names the status.
reset_fixture
LOGIN_CODE=401
check "refused login exits non-zero" not run_script
check "names the login status" out_has '401'
check "does not try to approve after a refused login" not log_has '/approve'

# 4. No build for this pipeline: the upload did not happen.
reset_fixture
BUILDS_BODY='{"data":[],"total":0}'
check "missing build exits non-zero" not run_script
check "points at the upload job" out_has 'test:screen-catalog'
check "does not approve without a build" not log_has '/approve'

# 5. Approve refused (e.g. the user lacks the editor role).
reset_fixture
APPROVE_CODE=403
check "refused approve exits non-zero" not run_script
check "names the approve status" out_has '403'

# 6. Unknown project name.
reset_fixture
PROJECTS_BODY='[{"id":"p-other","name":"other"}]'
check "unknown project exits non-zero" not run_script
check "names the project" out_has "VRT project 'vauchi' not found"

echo
echo "vrt-approve: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
