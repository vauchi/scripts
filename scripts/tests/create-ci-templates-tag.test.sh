#!/usr/bin/env bash
# SPDX-FileCopyrightText: 2026 Mattia Egloff <mattia.egloff@pm.me>
#
# SPDX-License-Identifier: GPL-3.0-or-later
#
# Sentinel suite for ci/create-ci-templates-tag.sh, the script behind the
# manual tag:ci-templates job (private#1068). curl is a stub that serves a
# canned tag list and records what the script posts; no network is used.

set -u

SCRIPT="$(cd "$(dirname "$0")/../.." && pwd)/scripts/ci/create-ci-templates-tag.sh"

pass=0
fail=0
assert_eq() {
    name="$1"; want="$2"; got="$3"
    if [ "$want" = "$got" ]; then
        pass=$((pass + 1)); printf '  PASS %s\n' "$name"
    else
        fail=$((fail + 1))
        printf '  FAIL %s\n    want: %s\n    got:  %s\n' "$name" "$want" "$got" >&2
    fi
}

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

# The stub answers GET .../repository/tags with $STUB_TAGS_STATUS and the
# body in $STUB_TAGS (page 1 only), records a POST's form fields, and
# answers it with $STUB_POST_STATUS.
cat >"$work/curl" <<'STUB'
#!/usr/bin/env bash
out="" ; write="" ; method=GET ; url="" ; fields=""
while [ $# -gt 0 ]; do
    case "$1" in
        -o) out="$2"; shift ;;
        -w) write="$2"; shift ;;
        -X) method="$2"; shift ;;
        --data-urlencode) fields="$fields $2"; method=POST; shift ;;
        -H|--header) shift ;;
        -*) ;;
        *) url="$1" ;;
    esac
    shift
done
if [ "$method" = POST ]; then
    printf '%s\n' "$fields" >>"$STUB_LOG"
    printf '{"name":"posted"}' >"$out"
    printf '%s' "$STUB_POST_STATUS"
    exit 0
fi
case "$url" in
    *page=1*|*page=1) printf '%s' "$STUB_TAGS" >"$out" ;;
    *) printf '[]' >"$out" ;;
esac
printf '%s' "$STUB_TAGS_STATUS"
STUB
chmod +x "$work/curl"

run() {
    : >"$work/log"
    CURL="$work/curl" STUB_LOG="$work/log" \
        PROJECT_ACCESS_TOKEN=token CI_API_V4_URL=https://gitlab.invalid/api/v4 \
        CI_PROJECT_ID=7 CI_COMMIT_SHA=bbbb TAG_DATE=2026-11-05 \
        "$SCRIPT" >"$work/out" 2>&1
    printf '%s' "$?"
}

export STUB_TAGS_STATUS=200 STUB_POST_STATUS=201
export STUB_TAGS='[{"name":"ci-templates-v2026.11.05","commit":{"id":"aaaa"}},{"name":"v1.0.0","commit":{"id":"bbbb"}}]'
assert_eq "an untagged commit gets the next tag" "0" "$(run)"
assert_eq "it posts that tag at the commit" \
    " tag_name=ci-templates-v2026.11.06 ref=bbbb message=ci-templates release from bbbb" \
    "$(cat "$work/log")"

export STUB_TAGS='[{"name":"ci-templates-v2026.11.05","commit":{"id":"bbbb"}}]'
assert_eq "a commit that already has a templates tag is refused" "1" "$(run)"
assert_eq "it posts nothing" "" "$(cat "$work/log")"
assert_eq "it names the existing tag" "1" "$(grep -c 'ci-templates-v2026.11.05' "$work/out")"

export STUB_TAGS='[]' STUB_TAGS_STATUS=401
assert_eq "an API error on the tag list fails" "1" "$(run)"
assert_eq "it posts nothing after the error" "" "$(cat "$work/log")"

export STUB_TAGS_STATUS=200 STUB_POST_STATUS=403
assert_eq "a refused tag creation fails" "1" "$(run)"

printf '\n%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
