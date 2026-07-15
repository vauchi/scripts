#!/usr/bin/env bash
# SPDX-FileCopyrightText: 2026 Mattia Egloff <mattia.egloff@pm.me>
#
# SPDX-License-Identifier: GPL-3.0-or-later

# cleanup-prerelease.sh — Delete stale dev/rc tags and packages
#
# Deletes git tags and packages with -dev, -rc, -alpha, -beta suffixes
# that are older than RETENTION_DAYS (default: 14).
#
# Handles up to 100 tags/packages per repo per run (GitLab API page limit).
# Weekly scheduling ensures this is sufficient for normal development velocity.
#
# Requires: GITLAB_TOKEN (api scope) or CI_JOB_TOKEN with cross-project access
# Usage:
#   GITLAB_TOKEN=glpat-xxx ./cleanup-prerelease.sh
#   GITLAB_TOKEN=glpat-xxx RETENTION_DAYS=7 DRY_RUN=1 ./cleanup-prerelease.sh

set -euo pipefail

# shellcheck source=lib/common.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib/common.sh"

: "${GITLAB_API:=https://gitlab.com/api/v4}"
: "${GITLAB_GROUP:=vauchi}"
: "${RETENTION_DAYS:=14}"
: "${DRY_RUN:=0}"

TOKEN="${GITLAB_TOKEN:-${CI_JOB_TOKEN:-}}"
if [ -z "$TOKEN" ]; then
  die "GITLAB_TOKEN or CI_JOB_TOKEN required"
fi

# macOS vs GNU date
if date -v-1d >/dev/null 2>&1; then
  CUTOFF=$(date -u -v-"${RETENTION_DAYS}"d +%Y-%m-%dT%H:%M:%SZ)
else
  CUTOFF=$(date -u -d "${RETENTION_DAYS} days ago" +%Y-%m-%dT%H:%M:%SZ)
fi

api() {
  local method="$1" path="$2"
  curl -sf -X "$method" \
    -H "PRIVATE-TOKEN: $TOKEN" \
    "${GITLAB_API}/${path}"
}

log_info "=== Prerelease Cleanup ==="
log_info "Retention: ${RETENTION_DAYS} days (cutoff: ${CUTOFF})"
log_info "Dry run: ${DRY_RUN}"

# Get all projects in group
PROJECTS=$(api GET "groups/${GITLAB_GROUP}/projects?per_page=100&include_subgroups=false" \
  | python3 -c "
import json, sys
for p in json.load(sys.stdin):
    if not p.get('archived') and 'deletion_scheduled' not in p.get('path',''):
        print(p['path'])
")

deleted_tags=0
deleted_pkgs=0

for repo in $PROJECTS; do
  encoded="${GITLAB_GROUP}%2F${repo}"

  # --- Tags ---
  tag_json=$(api GET "projects/${encoded}/repository/tags?per_page=100" 2>/dev/null || echo "[]")
  tags=$(echo "$tag_json" | python3 -c "
import json, sys
cutoff = sys.argv[1]
for t in json.load(sys.stdin):
    name = t['name']
    created = t.get('commit',{}).get('created_at','9999')
    if any(x in name for x in ['-dev','-rc','-alpha','-beta']) and created < cutoff:
        print(name)
" "$CUTOFF" 2>/dev/null || true)

  for tag in $tags; do
    if [ "$DRY_RUN" = "1" ]; then
      echo "  [DRY RUN] would delete tag ${repo}:${tag}"
    else
      api DELETE "projects/${encoded}/repository/tags/${tag}" >/dev/null 2>&1 || true
      echo "  deleted tag ${repo}:${tag}"
    fi
    deleted_tags=$((deleted_tags + 1))
  done

  # --- Packages ---
  pkg_json=$(api GET "projects/${encoded}/packages?per_page=100" 2>/dev/null || echo "[]")
  stale_pkgs=$(echo "$pkg_json" | python3 -c "
import json, sys
cutoff = sys.argv[1]
for p in json.load(sys.stdin):
    ver = p.get('version','')
    created = p.get('created_at','9999')
    if any(x in ver for x in ['-dev','-rc','-alpha','-beta']) and created < cutoff:
        print(str(p['id']) + ' ' + p['name'] + ':' + ver)
" "$CUTOFF" 2>/dev/null || true)

  # Use here-string to avoid subshell (preserves counter)
  while IFS= read -r line; do
    [ -z "$line" ] && continue
    pkg_id="${line%% *}"
    pkg_name="${line#* }"
    if [ "$DRY_RUN" = "1" ]; then
      echo "  [DRY RUN] would delete package ${repo}:${pkg_name} (id=${pkg_id})"
    else
      api DELETE "projects/${encoded}/packages/${pkg_id}" >/dev/null 2>&1 || true
      echo "  deleted package ${repo}:${pkg_name}"
    fi
    deleted_pkgs=$((deleted_pkgs + 1))
  done <<< "$stale_pkgs"
done

echo ""
echo "=== Summary ==="
echo "Tags deleted: ${deleted_tags}"
echo "Packages deleted: ${deleted_pkgs}"
