#!/usr/bin/env bash
# SPDX-FileCopyrightText: 2026 Mattia Egloff <mattia.egloff@pm.me>
#
# SPDX-License-Identifier: GPL-3.0-or-later

# The slim image has no Git. Without it Semgrep scans ignored Cargo caches.
# Exercise the actual setup in an image-like PATH, retaining a tracked
# first-party violation beside an ignored third-party violation.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
REAL_GIT="$(command -v git)"
REAL_SH="$(command -v sh)"
mkdir -p "$WORK/bin" "$WORK/repo/.cargo/registry"
git init -q "$WORK/repo"
printf '.cargo/*\n!.cargo/mutants.toml\n' > "$WORK/repo/.gitignore"
printf 'assert!(result.is_ok());\n' > "$WORK/repo/owned.rs"
printf 'assert!(dependency.is_ok());\n' > "$WORK/repo/.cargo/registry/dependency.rs"
git -C "$WORK/repo" add .gitignore owned.rs
awk '
  /^quality:semgrep-rules:/ { job = 1; next }
  job && /^  before_script:/ { setup = 1; next }
  setup && /^  [A-Za-z_]/ { exit }
  setup && /^    - / { sub(/^    - /, ""); print }
' "$SCRIPT_DIR/../../ci-templates/test-quality.yml" > "$WORK/setup"
test -s "$WORK/setup"
cat > "$WORK/bin/apt-get" <<EOF
#!$REAL_SH
for argument in "\$@"; do
  if [ "\$argument" = git ]; then
    /bin/ln -s "$REAL_GIT" "$WORK/bin/git"
  fi
done
EOF
printf '#!%s\nexit 0\n' "$REAL_SH" > "$WORK/bin/pip"
chmod +x "$WORK/bin/apt-get" "$WORK/bin/pip"
(
  cd "$WORK/repo"
  export PATH="$WORK/bin" SEMGREP_VERSION=1.174.0
  while IFS= read -r line; do "$REAL_SH" -ec "$line"; done < "$WORK/setup"
  git ls-files --cached --others --exclude-standard > "$WORK/visible"
)
grep -qx owned.rs "$WORK/visible"
if grep -q dependency.rs "$WORK/visible"; then
  echo 'FAIL: third-party cache remains visible' >&2
  exit 1
fi
echo 'quality-template-git: first-party source visible, third-party cache ignored'
