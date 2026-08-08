#!/usr/bin/env bash
# SPDX-FileCopyrightText: 2026 Mattia Egloff <mattia.egloff@pm.me>
# SPDX-License-Identifier: GPL-3.0-or-later

# Sentinel suite for check-ci-yaml-structure.sh — the local structural
# floor the pre-push hook falls back to when GitLab's lint endpoint is
# unreachable (403 from a token without lint permission).
#
# Per CC-27 every check ships with evidence it FAILS when the condition
# it watches is violated: each case below plants a known defect and
# asserts a non-zero exit, and the clean cases assert zero.

set -uo pipefail

DIR="$(cd "$(dirname "$0")/.." && pwd)"
SCRIPT="$DIR/check-ci-yaml-structure.sh"

pass=0
fail=0

assert_exit() {
    name="$1"; want="$2"; file="$3"
    sh "$SCRIPT" "$file" >/dev/null 2>&1
    got=$?
    if [ "$want" = "$got" ]; then
        printf '  PASS %s\n' "$name"
        pass=$((pass + 1))
    else
        printf '  FAIL %s (want exit %s, got %s)\n' "$name" "$want" "$got" >&2
        fail=$((fail + 1))
    fi
}

tmpfile() {
    f=$(mktemp)
    cat >"$f"
    printf '%s' "$f"
}

# ── 1. The real defect: a job's only variable removed ─────────────────
# This is the shape that shipped: dropping VAUCHI_LOCALES_DIR left four
# tui jobs with `variables:` pointing at null.
f=$(tmpfile <<'YAML'
test:unit:
  stage: test
  variables:
  script:
    - cargo test
YAML
)
assert_exit "empty variables: is reported" 1 "$f"
rm -f "$f"

# ── 2. Empty script: ──────────────────────────────────────────────────
f=$(tmpfile <<'YAML'
job:
  stage: test
  script:
YAML
)
assert_exit "empty script: at end of file is reported" 1 "$f"
rm -f "$f"

# ── 3. Empty before_script followed by a sibling key ──────────────────
f=$(tmpfile <<'YAML'
job:
  before_script:
  script:
    - make
YAML
)
assert_exit "empty before_script: is reported" 1 "$f"
rm -f "$f"

# ── 4. Populated keys stay silent ─────────────────────────────────────
f=$(tmpfile <<'YAML'
job:
  stage: test
  variables:
    FOO: "bar"
  before_script:
    - setup
  script:
    - cargo test
YAML
)
assert_exit "populated keys pass" 0 "$f"
rm -f "$f"

# ── 5. A blank line between key and body is not "empty" ───────────────
# YAML tolerates it, so the checker must not cry wolf.
f=$(tmpfile <<'YAML'
job:
  script:

    - cargo test
YAML
)
assert_exit "blank line before the body still passes" 0 "$f"
rm -f "$f"

# ── 6. A comment between key and body is not "empty" ──────────────────
f=$(tmpfile <<'YAML'
job:
  script:
    # explains the command below
    - cargo test
YAML
)
assert_exit "comment before the body still passes" 0 "$f"
rm -f "$f"

# ── 7. `!reference` bodies count as content ───────────────────────────
# The vauchi CI templates use these heavily; treating them as empty
# would fail every repo.
f=$(tmpfile <<'YAML'
job:
  before_script:
    - !reference [.self-hosted, before_script]
  script:
    - make
YAML
)
assert_exit "!reference body passes" 0 "$f"
rm -f "$f"

# ── 8. The real workspace files pass ──────────────────────────────────
# Guards against a checker so eager it rejects what already ships.
ws="$(cd "$DIR/../.." && pwd)"
for repo in core cli tui relay scripts; do
    ci="$ws/$repo/.gitlab-ci.yml"
    [ -f "$ci" ] || continue
    assert_exit "live $repo/.gitlab-ci.yml passes" 0 "$ci"
done

# ── 9. Usage errors are distinct from findings ────────────────────────
sh "$SCRIPT" >/dev/null 2>&1
if [ $? -eq 2 ]; then
    printf '  PASS missing argument exits 2, not 1\n'; pass=$((pass + 1))
else
    printf '  FAIL missing argument should exit 2\n' >&2; fail=$((fail + 1))
fi

sh "$SCRIPT" "/does/not/exist/$$.yml" >/dev/null 2>&1
if [ $? -eq 2 ]; then
    printf '  PASS missing file exits 2, not 1\n'; pass=$((pass + 1))
else
    printf '  FAIL missing file should exit 2\n' >&2; fail=$((fail + 1))
fi

printf '\n%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
