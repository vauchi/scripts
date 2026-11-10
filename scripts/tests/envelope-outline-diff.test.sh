#!/usr/bin/env bash
# SPDX-FileCopyrightText: 2026 Mattia Egloff <mattia.egloff@pm.me>
# SPDX-License-Identifier: GPL-3.0-or-later
#
# envelope-outline-diff.py: same outlines pass, a changed node fails, a log
# capture is read like a fixture (CC-27: the check must be able to fail).

set -euo pipefail
SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
DIFF="$SCRIPT_DIR/../envelope-outline-diff.py"
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

cat > "$WORK/core.json" <<'EOF'
{
  "my_info": [
    {"ReplaceSurface": {"surface_id": "my_info", "revision": 3, "surface": {
      "title": "len:12",
      "nodes": [
        {"Text": {"id": "hint", "content": "len:40", "text_style": "body"}},
        {"List": {"id": "entries", "rows": [
          {"title": "len:6", "subtitle": "len:16", "detail": "len:23", "selected": false}
        ]}}
      ]}}},
    {"SetContextBar": {"surface_id": "my_info", "revision": 3, "bar": {"actions": [
      {"interaction_id": "add_field", "label": "len:9", "tone": "Standard"}
    ]}}}
  ]
}
EOF

# A shell that received the same batch: the log line carries the batch.
{
  printf '11-10 09:41:00.000  1234  1234 I vauchi.presentation.outline: '
  python3 -c 'import json,sys; print(json.dumps(json.load(open(sys.argv[1]))["my_info"]))' "$WORK/core.json"
} > "$WORK/same.log"

if ! python3 "$DIFF" "$WORK/core.json" "$WORK/same.log" > "$WORK/out1.txt"; then
  echo "FAIL: identical outlines reported a difference"; cat "$WORK/out1.txt"; exit 1
fi
grep -q '^my_info: same outline' "$WORK/out1.txt" || { echo "FAIL: expected 'same outline'"; cat "$WORK/out1.txt"; exit 1; }

# A shell that dropped the row detail and changed the action's tone.
python3 - "$WORK/core.json" "$WORK/changed.json" <<'EOF'
import json, sys
doc = json.load(open(sys.argv[1]))
batch = doc["my_info"]
del batch[0]["ReplaceSurface"]["surface"]["nodes"][1]["List"]["rows"][0]["detail"]
batch[1]["SetContextBar"]["bar"]["actions"][0]["tone"] = "Serious"
json.dump(doc, open(sys.argv[2], "w"))
EOF

if python3 "$DIFF" "$WORK/core.json" "$WORK/changed.json" > "$WORK/out2.txt"; then
  echo "FAIL: a changed outline passed"; cat "$WORK/out2.txt"; exit 1
fi
grep -q 'rows\[0\]/detail: only on the left' "$WORK/out2.txt" || { echo "FAIL: dropped detail not reported"; cat "$WORK/out2.txt"; exit 1; }
grep -q 'actions\[0\]/tone: "Standard" != "Serious"' "$WORK/out2.txt" || { echo "FAIL: tone change not reported"; cat "$WORK/out2.txt"; exit 1; }

# Unusable input is a distinct status.
printf 'nothing here\n' > "$WORK/empty.log"
set +e
python3 "$DIFF" "$WORK/core.json" "$WORK/empty.log" > /dev/null 2>&1
rc=$?
set -e
[ "$rc" -eq 2 ] || { echo "FAIL: expected exit 2 for a capture without outlines, got $rc"; exit 1; }

printf 'ok — envelope-outline-diff passes identical outlines, fails changed ones, rejects empty input\n'
