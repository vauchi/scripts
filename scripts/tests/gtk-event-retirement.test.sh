#!/usr/bin/env bash
# SPDX-FileCopyrightText: 2026 Mattia Egloff <mattia.egloff@pm.me>
# SPDX-License-Identifier: GPL-3.0-or-later

set -euo pipefail

script_dir=$(cd "$(dirname "$0")" && pwd)
checker="$script_dir/../humble_check.py"
config="$script_dir/../humble_check_rules.json"
fixture=$(mktemp -d)
trap 'rm -rf "$fixture"' EXIT
mkdir -p "$fixture/linux-gtk/src"
printf '{"repos": {"linux-gtk": {}}}\n' > "$fixture/baseline.json"

for sample in 'use vauchi_core::api::VauchiEvent;' \
    'let screens = vauchi_app::ui::affected_screens(&event);' \
    'engine.vauchi().add_event_handler(handler);' \
    $'engine.vauchi()\n    .remove_event_handler(id);'; do
    printf '%s\n' '// TODO(HUMBLE): compatibility is not an exception' "$sample" > "$fixture/linux-gtk/src/app.rs"
    status=0
    python3 "$checker" --repo linux-gtk --repo-path "$fixture/linux-gtk" \
        --config "$config" --check "$fixture/baseline.json" > "$fixture/result" 2>&1 || status=$?
    if [[ $status != 1 ]] || ! grep -Fq '[retired_gtk_domain_events]' "$fixture/result"; then
        printf 'FAIL: retired GTK subscription must be rejected, got exit %s\n' "$status" >&2
        cat "$fixture/result" >&2
        exit 1
    fi
done

printf '%s\n' 'let rx = engine.subscribe_presentation_invalidations();' \
    'engine.dispatch(Event::PresentationInvalidated);' > "$fixture/linux-gtk/src/app.rs"
python3 "$checker" --repo linux-gtk --repo-path "$fixture/linux-gtk" \
    --config "$config" --check "$fixture/baseline.json"
printf 'PASS: retired GTK domain events rejected; opaque invalidation accepted\n'
