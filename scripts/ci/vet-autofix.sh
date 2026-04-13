#!/usr/bin/env bash
# SPDX-FileCopyrightText: 2026 Mattia Egloff <mattia.egloff@pm.me>
# SPDX-License-Identifier: GPL-3.0-or-later

# vet-autofix.sh — Run cargo-vet with auto-fix on main branch.
#
# When cargo-vet fails on the default branch (not MRs), regenerate
# exemptions and push a fix commit. This handles transitive dependency
# bumps (e.g. rustls patch releases) that propagate from core to
# downstream repos without manual intervention.
#
# Usage (in .gitlab-ci.yml script section):
#   - curl -sf "$CI_API_V4_URL/projects/77957857/repository/files/scripts%2Fci%2Fvet-autofix.sh/raw?ref=main" -o vet-autofix.sh
#   - chmod +x vet-autofix.sh
#   - ./vet-autofix.sh [--regenerate-lockfile]
#
# Options:
#   --regenerate-lockfile  Remove .cargo/config.toml and regenerate
#                          Cargo.lock before vetting (for repos with
#                          path overrides, e.g. cli, tui)
#
# Requirements:
#   - CI_COMMIT_BRANCH and CI_DEFAULT_BRANCH set by GitLab CI
#   - PROJECT_ACCESS_TOKEN variable (group-level CI variable, same as release/plan-sync)
#   - cargo-vet installed (caller's before_script)

set -euo pipefail

REGEN_LOCKFILE=false
for arg in "$@"; do
    case "$arg" in
        --regenerate-lockfile) REGEN_LOCKFILE=true ;;
    esac
done

# Step 1: Prepare lockfile
if $REGEN_LOCKFILE; then
    rm -f .cargo/config.toml
    cargo generate-lockfile 2>&1 | tail -5
fi

# Step 2: Try cargo vet
VET_FLAGS=()
if ! $REGEN_LOCKFILE; then
    VET_FLAGS=(--locked)
fi

if cargo vet "${VET_FLAGS[@]}" 2>&1; then
    echo "cargo vet passed"
    exit 0
fi

# Step 3: vet failed — auto-fix only on default branch
if [[ "${CI_COMMIT_BRANCH:-}" != "${CI_DEFAULT_BRANCH:-main}" ]]; then
    echo "cargo vet failed on non-default branch — not auto-fixing"
    exit 1
fi

echo "cargo vet failed on ${CI_DEFAULT_BRANCH} — attempting auto-fix..."

# Step 4: Regenerate exemptions (use same flags as the vet check)
cargo vet "${VET_FLAGS[@]}" regenerate exemptions 2>&1
cargo vet "${VET_FLAGS[@]}" fmt 2>&1

# Step 5: Verify the fix works
if ! cargo vet "${VET_FLAGS[@]}" 2>&1; then
    echo "Auto-fix failed — cargo vet still failing after regeneration"
    exit 1
fi

# Step 6: Check if anything changed
if git diff --quiet supply-chain/; then
    echo "No exemption changes needed (unexpected — vet passed after regen but no diff)"
    exit 0
fi

echo "Exemption changes:"
git diff --stat supply-chain/

# Step 7: Commit and push
# Uses PROJECT_ACCESS_TOKEN (group-level CI variable), same pattern as
# release.yml and plan-sync.yml. CI_JOB_TOKEN cannot push to protected branches.
git config user.name "vauchi-gitlab-runner"
git config user.email "noreply@vauchi.app"
git remote set-url origin "https://vauchi-gitlab-runner:${PROJECT_ACCESS_TOKEN}@gitlab.com/${CI_PROJECT_PATH}.git"

git add supply-chain/
git commit -m "chore: auto-regenerate cargo-vet exemptions

Triggered by transitive dependency update on ${CI_DEFAULT_BRANCH}."

git push origin "HEAD:${CI_DEFAULT_BRANCH}"

echo "Auto-fix committed and pushed to ${CI_DEFAULT_BRANCH}"
