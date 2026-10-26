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

for sample in 'engine.on_wakeup();' \
    $'engine\n .drain_pending_notifications();' \
    'engine.poll_notifications();' \
    'AppEngine::on_wakeup(&mut engine);' \
    'use vauchi_app::notification_types::NotificationPriority;' \
    'let pending: Vec<PendingNotification> = Vec::new();'; do
    printf '%s\n' '// TODO(HUMBLE): compatibility is not an exception' "$sample" > "$fixture/linux-gtk/src/app.rs"
    status=0
    python3 "$checker" --repo linux-gtk --repo-path "$fixture/linux-gtk" \
        --config "$config" --check "$fixture/baseline.json" > "$fixture/result" 2>&1 || status=$?
    if [[ $status != 1 ]] || ! grep -Fq '[retired_gtk_notification_collection]' "$fixture/result"; then
        printf 'FAIL: legacy GTK notification collection must be rejected, got exit %s\n' "$status" >&2
        cat "$fixture/result" >&2
        exit 1
    fi
done

printf '%s\n' 'engine.dispatch(Event::WakeupFired);' \
    'Command::PostNotification { notification };' \
    'NotificationUrgency::Urgent;' \
    'application.send_notification(notification.notification_id.as_deref(), &native);' > "$fixture/linux-gtk/src/app.rs"
python3 "$checker" --repo linux-gtk --repo-path "$fixture/linux-gtk" \
    --config "$config" --check "$fixture/baseline.json"
printf 'PASS: legacy GTK notification collection rejected; canonical commands accepted\n'
