#!/usr/bin/env bash
# SPDX-FileCopyrightText: 2026 Mattia Egloff <mattia.egloff@pm.me>
# SPDX-License-Identifier: GPL-3.0-or-later

set -euo pipefail

script_dir=$(cd "$(dirname "$0")" && pwd)
checker="$script_dir/../humble_check.py"
config="$script_dir/../humble_check_rules.json"
fixture=$(mktemp -d)
trap 'rm -rf "$fixture"' EXIT
printf '{"repos": {"android": {}, "ios": {}}}\n' > "$fixture/baseline.json"

expect_rejected() {
    local repo=$1 source_file=$2 rule=$3 sample=$4 status=0
    printf '%s\n' '// TODO(HUMBLE): old compatibility example' "$sample" > "$source_file"
    python3 "$checker" --repo "$repo" --repo-path "$fixture/$repo" \
        --config "$config" --check "$fixture/baseline.json" > "$fixture/result" 2>&1 || status=$?
    if [[ $status != 1 ]] || ! grep -Fq "[$rule]" "$fixture/result"; then
        printf 'FAIL: %s must reject %s through %s, got exit %s\n' "$repo" "$sample" "$rule" "$status" >&2
        cat "$fixture/result" >&2
        exit 1
    fi
}

for repo in android ios; do
    if [[ $repo == android ]]; then
        source_dir="$fixture/$repo/app/src/main"
        source_file="$source_dir/Preferences.kt"
    else
        source_dir="$fixture/$repo/Vauchi"
        source_file="$source_dir/Preferences.swift"
    fi
    mkdir -p "$source_dir"
    for symbol in hasCompletedOnboarding setOnboardingCompleted hasDismissedDemoContact \
        setDemoContactDismissed resetOnboarding onboarding_completed demo_contact_dismissed \
        KEY_ONBOARDING_COMPLETED KEY_DEMO_CONTACT_DISMISSED; do
        expect_rejected "$repo" "$source_file" retired_onboarding_preferences "$symbol"
    done
    if [[ $repo == android ]]; then
        for symbol in MobileSyncResult DomainCommand.Sync $'DomainCommand\n    .Sync'; do
            expect_rejected "$repo" "$source_file" retired_android_sync_result "$symbol"
        done
    fi
    printf '%s\n' 'let relayUrl = "https://relay.example"' 'let reduceMotion = true' > "$source_file"
    python3 "$checker" --repo "$repo" --repo-path "$fixture/$repo" \
        --config "$config" --check "$fixture/baseline.json"
done
printf 'PASS: retired mobile paths reject seeded violations and accept native settings\n'
