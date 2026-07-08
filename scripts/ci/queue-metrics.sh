#!/usr/bin/env bash
# SPDX-FileCopyrightText: 2026 Mattia Egloff <mattia.egloff@pm.me>
#
# SPDX-License-Identifier: GPL-3.0-or-later

# queue-metrics.sh — Collect CI runner queue metrics and push to Prometheus.
#
# Monitors running/pending jobs across the vauchi group, computes average
# queue (wait) time per runner tag, and pushes gauges to the Pushgateway.
# Intended to run every few minutes from a scheduled CI job.
#
# Usage:
#   queue-metrics.sh --ci                 # CI mode: collect + push
#   queue-metrics.sh --dry-run            # Print metrics, do not push
#   queue-metrics.sh --ci --dry-run       # CI collect to stdout
#
# Environment:
#   CI_JOB_TOKEN       — GitLab CI token (CI mode)
#   GITLAB_TOKEN       — Personal token (local mode)
#   PUSHGATEWAY_URL    — Optional direct pushgateway URL
#   DEPLOY_SSH_PRIVATE_KEY / PUSHGATEWAY_SSH_KEY — SSH push keys

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
GITLAB_API="https://gitlab.com/api/v4"
GROUP_PATH="vauchi"

CI_MODE=false
DRY_RUN=false

for arg in "$@"; do
    case "$arg" in
        --ci) CI_MODE=true ;;
        --dry-run) DRY_RUN=true ;;
        --help|-h)
            sed -n '6,/^$/p' "$0" | sed 's/^# //' | sed 's/^#//'
            exit 0
            ;;
    esac
done

TOKEN="${GITLAB_TOKEN:-${CI_JOB_TOKEN:-}}"
if [ -z "$TOKEN" ]; then
    echo "ERROR: GITLAB_TOKEN or CI_JOB_TOKEN required" >&2
    exit 1
fi

api_get() {
    local url="$1"
    curl -sf --max-time 30 -H "PRIVATE-TOKEN: ${TOKEN}" "$url" 2>/dev/null
}

# Collect running/pending jobs for a project and emit per-tag stats as JSON objects.
# Args: project_path (e.g. vauchi/core)
# Output stream: one JSON object per tag with keys tag, queued_seconds, pending_count.
collect_project() {
    local project="$1"
    local enc_project
    enc_project=$(python3 -c "import urllib.parse,sys; print(urllib.parse.quote(sys.argv[1], safe=''))" "$project")
    local url="${GITLAB_API}/projects/${enc_project}/jobs?scope[]=running&scope[]=pending&per_page=100"

    local now_epoch
    now_epoch=$(date -u +%s)

    api_get "$url" | python3 - "$now_epoch" - 2>/dev/null <<'PY'
import sys, json
now_epoch = int(sys.argv[1])
data = json.load(sys.stdin)
if not isinstance(data, list):
    sys.exit(0)

by_tag = {}
for job in data:
    tags = job.get("tag_list") or ["untagged"]
    tag = tags[0]
    entry = by_tag.setdefault(tag, {"queued_seconds": 0.0, "count": 0, "pending": 0})

    status = job.get("status", "")
    created = job.get("created_at")
    started = job.get("started_at")
    queued_duration = job.get("queued_duration")

    if status == "pending":
        entry["pending"] += 1
        # Estimate wait as now - created_at
        if created:
            try:
                from datetime import datetime, timezone
                dt = datetime.fromisoformat(created.replace("Z", "+00:00"))
                wait = now_epoch - int(dt.timestamp())
                if wait > 0:
                    entry["queued_seconds"] += wait
                    entry["count"] += 1
            except Exception:
                pass
    elif status in ("running",):
        if queued_duration is not None:
            entry["queued_seconds"] += float(queued_duration)
            entry["count"] += 1
        elif created and started:
            try:
                from datetime import datetime, timezone
                cdt = datetime.fromisoformat(created.replace("Z", "+00:00"))
                sdt = datetime.fromisoformat(started.replace("Z", "+00:00"))
                wait = int(sdt.timestamp()) - int(cdt.timestamp())
                if wait > 0:
                    entry["queued_seconds"] += wait
                    entry["count"] += 1
            except Exception:
                pass

for tag, vals in by_tag.items():
    avg = vals["queued_seconds"] / vals["count"] if vals["count"] else 0.0
    print(json.dumps({"tag": tag, "avg_queued_seconds": avg, "pending": vals["pending"], "sample_count": vals["count"]}))
PY
}

# Discover projects in the vauchi group (public + accessible to token).
project_list() {
    api_get "${GITLAB_API}/groups/${GROUP_PATH}/projects?per_page=100&simple=true" | \
        python3 -c "import sys,json; data=json.load(sys.stdin); print('\n'.join(p['path_with_namespace'] for p in data if isinstance(data,list)))" 2>/dev/null
}

# Aggregate per-tag across all projects.
aggregate() {
    python3 - <<'PY'
import sys, json
from collections import defaultdict
agg = defaultdict(lambda: {"queued_seconds": 0.0, "count": 0, "pending": 0})
for line in sys.stdin:
    line = line.strip()
    if not line:
        continue
    try:
        obj = json.loads(line)
    except json.JSONDecodeError:
        continue
    tag = obj.get("tag", "unknown")
    entry = agg[tag]
    entry["queued_seconds"] += obj.get("avg_queued_seconds", 0.0) * obj.get("sample_count", 0)
    entry["count"] += obj.get("sample_count", 0)
    entry["pending"] += obj.get("pending", 0)

for tag, vals in sorted(agg.items()):
    avg = vals["queued_seconds"] / vals["count"] if vals["count"] else 0.0
    print(json.dumps({"tag": tag, "avg_queued_seconds": avg, "pending": vals["pending"], "sample_count": vals["count"]}))
PY
}

# Build Prometheus text from aggregated JSON.
build_metrics() {
    local timestamp
    timestamp=$(date +%s)
    cat <<EOF
# HELP vauchi_ci_runner_queue_duration_seconds Average job queue/wait time by runner tag
# TYPE vauchi_ci_runner_queue_duration_seconds gauge
EOF
    while IFS= read -r line; do
        local tag avg pending
        tag=$(echo "$line" | python3 -c "import sys,json; print(json.load(sys.stdin)['tag'])")
        avg=$(echo "$line" | python3 -c "import sys,json; print(json.load(sys.stdin)['avg_queued_seconds'])")
        pending=$(echo "$line" | python3 -c "import sys,json; print(json.load(sys.stdin)['pending'])")
        printf 'vauchi_ci_runner_queue_duration_seconds{tag="%s"} %.3f %d\n' "$tag" "$avg" "$timestamp"
        printf 'vauchi_ci_runner_pending_jobs{tag="%s"} %d %d\n' "$tag" "$pending" "$timestamp"
    done

    cat <<EOF
# HELP vauchi_ci_runner_queue_sample_count Jobs sampled for queue average by runner tag
# TYPE vauchi_ci_runner_queue_sample_count gauge
EOF
    while IFS= read -r line; do
        local tag count
        tag=$(echo "$line" | python3 -c "import sys,json; print(json.load(sys.stdin)['tag'])")
        count=$(echo "$line" | python3 -c "import sys,json; print(json.load(sys.stdin)['sample_count'])")
        printf 'vauchi_ci_runner_queue_sample_count{tag="%s"} %d %d\n' "$tag" "$count" "$timestamp"
    done
}

# Collect and aggregate.
AGGREGATED=$(mktemp)
trap 'rm -f "$AGGREGATED"' EXIT

for project in $(project_list); do
    collect_project "$project" 2>/dev/null || true
done | aggregate > "$AGGREGATED"

METRICS_TEXT=$(build_metrics < "$AGGREGATED")

if [ "$DRY_RUN" = true ]; then
    echo "$METRICS_TEXT"
    exit 0
fi

if [ "$CI_MODE" = true ]; then
    source "$SCRIPT_DIR/setup-ssh-pushgateway.sh"
    setup_ssh_pushgateway
    if ! pushgateway_push "$METRICS_TEXT" "/metrics/job/vauchi_ci_runner_queue"; then
        echo "ERROR: failed to push queue metrics" >&2
        exit 1
    fi
    echo "Queue metrics pushed."
else
    echo "$METRICS_TEXT"
fi
