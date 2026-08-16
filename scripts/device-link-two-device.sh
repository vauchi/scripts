#!/usr/bin/env bash
# SPDX-FileCopyrightText: 2026 Mattia Egloff <mattia.egloff@pm.me>
#
# SPDX-License-Identifier: GPL-3.0-or-later

# device-link-two-device.sh — drive a whole device-link ceremony across
# two Android devices and assert the joiner ends up holding the host's
# identity.
#
# Why this exists as a script rather than a Maestro flow: Maestro drives
# one device per invocation, and this ceremony needs two acting in
# lockstep inside a 60-second confirmation window.
#
# Why it exists at all: device linking shipped broken — the joiner minted
# a return-channel code the relay refused, so no link could ever complete
# (2026-08-14-device-link-host-never-shows-the-confirmation-code). The
# Maestro flow stayed green throughout, because it asserts only that
# "Generating link…" disappears. This asserts the thing that was broken.
#
# Usage:
#   device-link-two-device.sh <host-serial> <joiner-serial> [evidence-dir]
#
# Environment:
#   NAME          Host identity's display name, asserted on the joiner
#                 (default: "Maestro Test" — matches the gate's flows)
#   APP_ID        Android application id (default: app.vauchi)
#   STEP_TIMEOUT  Seconds to wait for any single screen (default: 40)
#
# Exit codes: 0 = the two devices linked, 1 = they did not, 2 = usage or
#             a missing precondition (device absent, app not installed).

set -uo pipefail

APP_ID="${APP_ID:-app.vauchi}"
NAME="${NAME:-Maestro Test}"
STEP_TIMEOUT="${STEP_TIMEOUT:-40}"

RED=$'\033[0;31m'
GREEN=$'\033[0;32m'
YELLOW=$'\033[1;33m'
NC=$'\033[0m'

if [[ $# -lt 2 ]]; then
    echo "usage: $0 <host-serial> <joiner-serial> [evidence-dir]" >&2
    exit 2
fi

HOST="$1"
JOINER="$2"
EVIDENCE="${3:-}"
[[ -n "$EVIDENCE" ]] && mkdir -p "$EVIDENCE"

note() { printf '    %s\n' "$*"; }
fail() {
    printf '%b\n' "    ${RED}$*${NC}" >&2
    exit 1
}

# ── device plumbing ──────────────────────────────────────────────────

dump() {
    # uiautomator writes to /dev/tty; a device mid-transition can answer
    # with an empty document, so callers retry rather than trust one read.
    adb -s "$1" exec-out uiautomator dump /dev/tty 2>/dev/null
}

labels() {
    dump "$1" | grep -oE '(text|content-desc)="[^"]+"' | sed 's/^[a-z-]*="//; s/"$//' | sort -u
}

has_label() {
    labels "$1" | grep -qxF "$2"
}

# Tap a node by its exact text or content-desc. Both are checked because
# ADR-066 left the shells without automation ids — labels are the only
# handle a user-driven test has.
tap_label() {
    local serial="$1" label="$2" xml coords
    xml=$(dump "$serial")
    coords=$(LABEL="$label" python3 -c '
import os, re, sys
label = os.environ["LABEL"]
doc = sys.stdin.read()
for node in re.finditer(r"<node[^>]*>", doc):
    tag = node.group(0)
    if f"text=\"{label}\"" in tag or f"content-desc=\"{label}\"" in tag:
        box = re.search(r"bounds=\"\[(\d+),(\d+)\]\[(\d+),(\d+)\]\"", tag)
        if box:
            x1, y1, x2, y2 = (int(v) for v in box.groups())
            print((x1 + x2) // 2, (y1 + y2) // 2)
            break
' <<<"$xml")
    [[ -z "$coords" ]] && return 1
    local x y
    read -r x y <<<"$coords"
    adb -s "$serial" shell input tap "$x" "$y" >/dev/null 2>&1
}

wait_for_label() {
    local serial="$1" label="$2" deadline=$((SECONDS + STEP_TIMEOUT))
    while (( SECONDS < deadline )); do
        has_label "$serial" "$label" && return 0
        sleep 2
    done
    return 1
}

tap_when_ready() {
    local serial="$1" label="$2"
    wait_for_label "$serial" "$label" || return 1
    tap_label "$serial" "$label"
}

screenshot() {
    [[ -n "$EVIDENCE" ]] || return 0
    adb -s "$1" exec-out screencap -p >"$EVIDENCE/$2.png" 2>/dev/null
}

# Read the device-link QR off the host's screen. The payload is a
# `vauchi://device-link?qr=…` deep link, which is what lets this run
# without a camera. `zbarimg` cannot read this QR — it is dense and the
# on-screen contrast is low — so macOS Vision does the decoding; that is
# also why this gate is macOS-only for now.
decode_host_qr() {
    local serial="$1" png
    png=$(mktemp -t vauchi-qr).png
    # The screenshot can win a race against the QR's first paint, so this
    # retries rather than reporting a missing QR.
    for _ in 1 2 3 4 5 6; do
        adb -s "$serial" exec-out screencap -p >"$png" 2>/dev/null
        if [[ -s "$png" ]]; then
            local url
            url=$(swift "$(dirname "${BASH_SOURCE[0]}")/decode-qr.swift" "$png" 2>/dev/null | head -1)
            if [[ "$url" == vauchi://device-link* ]]; then
                printf '%s' "$url"
                rm -f "$png"
                return 0
            fi
        fi
        sleep 3
    done
    rm -f "$png"
    return 1
}

# ── preconditions ────────────────────────────────────────────────────

for serial in "$HOST" "$JOINER"; do
    adb -s "$serial" get-state >/dev/null 2>&1 \
        || { echo "device $serial is not attached" >&2; exit 2; }
    adb -s "$serial" shell pm list packages 2>/dev/null | grep -q "$APP_ID" \
        || { echo "$APP_ID is not installed on $serial" >&2; exit 2; }
done
command -v swift >/dev/null 2>&1 \
    || { echo "swift is required to decode the QR (macOS only)" >&2; exit 2; }

printf '%b\n' "${YELLOW}  two-device link: host=$HOST joiner=$JOINER${NC}"

# ── 1. joiner starts with no identity ────────────────────────────────
# Adopting an identity is refused outright when one already exists, so a
# joiner carrying state fails for a reason that has nothing to do with
# the ceremony.
note "joiner: clearing state"
adb -s "$JOINER" shell pm clear "$APP_ID" >/dev/null 2>&1
adb -s "$JOINER" shell am force-stop "$APP_ID" >/dev/null 2>&1

# ── 2. host publishes a link ─────────────────────────────────────────
note "host: opening Devices → Link New Device"
adb -s "$HOST" shell am force-stop "$APP_ID" >/dev/null 2>&1
adb -s "$HOST" shell am start -n "$APP_ID/.MainActivity" >/dev/null 2>&1
wait_for_label "$HOST" "More" || fail "host never reached a rendered screen"
tap_label "$HOST" "More" || fail "host: no More affordance"
tap_when_ready "$HOST" "Devices" || fail "host: no Devices destination — does it have an identity?"
tap_when_ready "$HOST" "Link New Device" || fail "host: no Link New Device affordance"

wait_for_label "$HOST" "Scan on new device" \
    || fail "host never rendered a QR (generation stuck?)"
screenshot "$HOST" "link_host_qr"

URL=$(decode_host_qr "$HOST") \
    || fail "could not decode the host's QR after several attempts"
note "host: QR decoded"

# ── 3. joiner claims it ──────────────────────────────────────────────
# A joiner left on a previous ceremony's waiting screen never claims the
# new QR, and the host then legitimately shows nothing — which reads
# exactly like the host being broken. Starting from a cold app avoids it.
note "joiner: opening the link"
adb -s "$JOINER" shell am start -a android.intent.action.VIEW -d "'$URL'" >/dev/null 2>&1
wait_for_label "$JOINER" "Confirm" || fail "joiner never reached the join screen"

# A fresh name each run: the registry refuses a device name it already
# holds, and that refusal surfaces as a generic linking failure.
DEVICE_NAME="gate-$(date +%H%M%S)"
tap_label "$JOINER" "Name for this device" >/dev/null 2>&1
adb -s "$JOINER" shell input text "$DEVICE_NAME" >/dev/null 2>&1
adb -s "$JOINER" shell input keyevent 4 >/dev/null 2>&1  # hide keyboard
sleep 1
tap_when_ready "$JOINER" "Confirm" || fail "joiner: no Confirm affordance"

# ── 4. host confirms inside the 60 s window ──────────────────────────
# ADR-035 gives the QR five minutes but the confirmation only sixty
# seconds, so this polls fast and taps the moment the code appears.
note "host: waiting for the confirmation prompt"
CONFIRM_LABEL="Codes Match — Verify Proximity"
confirmed=0
deadline=$((SECONDS + 55))
while (( SECONDS < deadline )); do
    if has_label "$HOST" "$CONFIRM_LABEL"; then
        screenshot "$HOST" "link_host_confirm"
        tap_label "$HOST" "$CONFIRM_LABEL" && confirmed=1
        break
    fi
    sleep 2
done
(( confirmed )) || fail "host never offered the confirmation inside the window"
note "host: confirmed"

# ── 5. both sides must land ──────────────────────────────────────────
wait_for_label "$HOST" "Device Linked" \
    || { screenshot "$HOST" "link_host_end"; fail "host did not report a completed link"; }
screenshot "$HOST" "link_host_done"

# The joiner adopting the identity is the whole point: it must now render
# the *host's* display name as its own.
if ! wait_for_label "$JOINER" "$NAME"; then
    screenshot "$JOINER" "link_joiner_end"
    fail "joiner never adopted the identity (expected to see \"$NAME\")"
fi
screenshot "$JOINER" "link_joiner_done"

printf '%b\n' "    ${GREEN}two devices linked: joiner adopted \"$NAME\"${NC}"
exit 0
