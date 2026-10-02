#!/usr/bin/env bash
# SPDX-FileCopyrightText: 2026 Mattia Egloff <mattia.egloff@pm.me>
#
# SPDX-License-Identifier: GPL-3.0-or-later
#
# .design-drift-job has a before_script of its own, so it inherits no
# fetch_vauchi_script from rust-base, yet its script calls it to download the
# push helper. The call failed as "command not found", its stderr went to
# /dev/null, and every repository logged "Could not download pushgateway
# helper — metrics skipped" (cli job 16893315297): the design-drift group was
# never pushed at all (private#470).

set -u

TEMPLATE="$(cd "$(dirname "$0")/../.." && pwd)/ci-templates/design-drift.yml"

pass=0
fail=0
check() {
    name="$1"; want="$2"; got="$3"
    if [ "$want" = "$got" ]; then
        pass=$((pass + 1)); printf '  PASS %s\n' "$name"
    else
        fail=$((fail + 1))
        printf '  FAIL %s\n    want: %s\n    got:  %s\n' "$name" "$want" "$got" >&2
    fi
}

# The job's own block: from its key to the next top-level key.
job=$(awk '/^\.design-drift-job:/ { on = 1; print; next } on && /^[^[:space:]#]/ { exit } on { print }' "$TEMPLATE")

check "the job block was found" "1" "$([ -n "$job" ] && echo 1 || echo 0)"
check "the job calls fetch_vauchi_script" "1" \
    "$(printf '%s\n' "$job" | grep -c 'if fetch_vauchi_script ' | head -1)"
check "the job defines fetch_vauchi_script itself" "1" \
    "$(printf '%s\n' "$job" | grep -c 'fetch_vauchi_script() {')"
check "a failed download keeps its error message" "0" \
    "$(printf '%s\n' "$job" | grep -c 'fetch_vauchi_script .* 2>/dev/null')"

# The definition must work in the job's shell: extract it and fetch through
# a stub curl under plain sh.
work=$(mktemp -d)
mkdir -p "$work/bin"
cat > "$work/bin/curl" <<'STUB'
#!/bin/sh
out=""; prev=""
for a in "$@"; do [ "$prev" = "-o" ] && out="$a"; prev="$a"; done
printf '%s\n' "$*" > "$out.args"
echo "fetched" > "$out"
STUB
chmod +x "$work/bin/curl"
printf '%s\n' "$job" | awk '/fetch_vauchi_script\(\) \{/ { on = 1 } on { sub(/^      /, ""); print } on && /^\}/ { exit }' > "$work/fn.sh"
got=$(cd "$work" && PATH="$work/bin:$PATH" CI_JOB_TOKEN=t CI_API_V4_URL=https://gitlab.example/api/v4 \
    VAUCHI_SCRIPTS_REF=some-tag sh -c '. ./fn.sh && fetch_vauchi_script scripts/ci/x.sh out/x.sh && cat out/x.sh' 2>&1)
check "the definition fetches a script under plain sh" "fetched" "$got"
check "it asks for the pinned ref" "1" \
    "$(grep -c 'scripts%2Fci%2Fx.sh/raw?ref=some-tag' "$work/out/x.sh.args" 2>/dev/null || echo 0)"
rm -rf "$work"

printf '\n%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
