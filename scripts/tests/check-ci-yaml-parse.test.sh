#!/usr/bin/env bash
# SPDX-FileCopyrightText: 2026 Mattia Egloff <mattia.egloff@pm.me>
# SPDX-License-Identifier: GPL-3.0-or-later

# check-ci-yaml-parse.sh parses CI files locally, so a syntax error is
# caught in any of them — including a `local:` include server lint would
# read from main instead (private#779). The two broken cases are the two
# errors core!1945 shipped with (#767); the valid case uses GitLab's
# `!reference` tag, which a plain YAML loader rejects.

set -uo pipefail

DIR="$(cd "$(dirname "$0")/../.." && pwd)"
CHECK="$DIR/scripts/check-ci-yaml-parse.sh"

pass=0
fail=0
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

expect_exit() {
    local name="$1" want="$2"
    shift 2
    local got=0
    sh "$CHECK" "$@" >/dev/null 2>&1 || got=$?
    if [ "$got" = "$want" ]; then
        printf '  PASS %s\n' "$name"; pass=$((pass + 1))
    else
        printf '  FAIL %s — exit %s, want %s\n' "$name" "$got" "$want" >&2
        fail=$((fail + 1))
    fi
}

cat > "$work/valid.yml" <<'EOF'
.setup:
  before_script: [echo setup]
job:
  before_script:
    - !reference [.setup, before_script]
  cache:
    fallback_keys: ["core-32bit-${CI_DEFAULT_BRANCH}"]
  script:
    - 'test 1 = 1 || { echo "ERROR: wrong"; exit 1; }'
EOF

cat > "$work/flow-sequence.yml" <<'EOF'
job:
  cache:
    fallback_keys: [core-32bit-${CI_DEFAULT_BRANCH}]
  script: [true]
EOF

cat > "$work/colon-in-script.yml" <<'EOF'
job:
  script:
    - test 1 = 1 || { echo "ERROR: wrong"; exit 1; }
EOF

# The hook reads `local:` includes only from a list of mappings; any other
# include form would quietly bypass its include checks, so it fails.
printf 'include:\n  - local: ci/a.yml\n  - project: vauchi/scripts\n    file: /x.yml\n' > "$work/include-list.yml"
printf "include: 'ci/a.yml'\n" > "$work/include-string.yml"
printf 'include:\n  - ci/a.yml\n' > "$work/include-string-item.yml"
printf 'include:\n  local: ci/a.yml\n' > "$work/include-mapping.yml"

expect_exit "include as a list of mappings → 0" 0 "$work/include-list.yml"
expect_exit "include as a bare string → 1" 1 "$work/include-string.yml"
expect_exit "include list with a bare string item → 1" 1 "$work/include-string-item.yml"
expect_exit "include as a single mapping → 1" 1 "$work/include-mapping.yml"
expect_exit "valid file with !reference → 0" 0 "$work/valid.yml"
expect_exit "unquoted \${...} in a flow sequence (#767) → 1" 1 "$work/flow-sequence.yml"
expect_exit "unquoted ': ' in a script line (#767) → 1" 1 "$work/colon-in-script.yml"
expect_exit "one bad file among good ones → 1" 1 "$work/valid.yml" "$work/flow-sequence.yml"
expect_exit "no file given → usage error" 2

cat > "$work/inputs.yml" <<'EOF'
spec:
  inputs:
    audit:
      default: off
---
job:
  script:
    - echo checked
EOF
cat > "$work/inputs-bad-job.yml" <<'EOF'
spec:
  inputs:
    audit:
      default: off
---
job:
  script:
    - echo error: invalid script mapping
EOF
expect_exit "pipeline inputs header and job document → 0" 0 "$work/inputs.yml"
expect_exit "invalid job after inputs header → 1" 1 "$work/inputs-bad-job.yml"

printf '\n%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
