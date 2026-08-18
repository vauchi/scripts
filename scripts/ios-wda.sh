#!/usr/bin/env bash
# SPDX-FileCopyrightText: 2026 Mattia Egloff <mattia.egloff@pm.me>
#
# SPDX-License-Identifier: GPL-3.0-or-later
#
# Drive a physical iPhone through WebDriverAgent.
#
# Every rule encoded here was learned the hard way on 2026-08-17 while
# driving an iPhone SE, and each one silently wastes a session if broken:
#
#   * Element `/click` is a NO-OP on this device. It returns HTTP 200 and
#     nothing moves. Only W3C pointer actions at the element's centre
#     register, so every tap here goes through `/actions`.
#   * A tap's HTTP 200 is NOT evidence it landed. Callers verify against
#     the hierarchy; `tap-label` re-reads and reports what it saw.
#   * An off-screen element still returns a rect — y=779 on a 667pt
#     screen, or y=-72 after over-scrolling. Tapping either does nothing.
#     So `tap-label` scrolls until the target is inside the viewport and
#     checks BOTH bounds, not just the lower one.
#   * The session needs `bundleId: app.vauchi.ios`. `app.vauchi` is the
#     Android package and WDA rejects it with "Application info provider
#     returned nil".
#   * A system permission alert belongs to springboard, not the app, so
#     an app-scoped session cannot dismiss it. `accept-alert` opens an
#     unscoped session for that.
#
# Usage:
#   ios-wda.sh session [bundle_id]      Start a session, print its id
#   ios-wda.sh tap-label <label>        Scroll into view, tap, verify
#   ios-wda.sh tap-fixed <label>        Tap where it is (command bar)
#   ios-wda.sh tap-name <name>          Tap by accessibility identifier
#   ios-wda.sh labels                   Print Buttons/StaticTexts on screen
#   ios-wda.sh accept-alert             Dismiss a springboard permission alert
#
# Environment:
#   WDA_URL      default http://127.0.0.1:8100 (go-ios USB forward)
#   WDA_SESSION  session id; `session` writes it to $WDA_SESSION_FILE
#   WDA_SESSION_FILE  default ${TMPDIR:-/tmp}/vauchi-wda-session
#
# Exit: 0 ok, 1 not found / not reachable, 2 usage.

set -uo pipefail

WDA_URL="${WDA_URL:-http://127.0.0.1:8100}"
WDA_SESSION_FILE="${WDA_SESSION_FILE:-${TMPDIR:-/tmp}/vauchi-wda-session}"
BUNDLE_DEFAULT="app.vauchi.ios"
# Viewport is read from the device rather than assumed: the same flow runs
# on an SE and a Pro Max, and a hardcoded height silently mis-clips one.
VIEWPORT_H=""

api() { curl -s --max-time 30 "$@"; }

session_id() {
    if [ -n "${WDA_SESSION:-}" ]; then printf '%s' "$WDA_SESSION"; return; fi
    [ -f "$WDA_SESSION_FILE" ] && cat "$WDA_SESSION_FILE"
}

start_session() {
    local bundle="${1:-$BUNDLE_DEFAULT}" body
    body=$(api -X POST "$WDA_URL/session" -H 'Content-Type: application/json' \
        -d "{\"capabilities\":{\"alwaysMatch\":{\"bundleId\":\"$bundle\",\"shouldWaitForQuiescence\":false}}}")
    local sid
    sid=$(printf '%s' "$body" | python3 -c '
import json, sys
try:
    print(json.load(sys.stdin)["value"].get("sessionId", ""))
except Exception:
    print("")')
    if [ -z "$sid" ]; then
        echo "could not start a session for $bundle" >&2
        printf '%s\n' "$body" | head -c 400 >&2
        return 1
    fi
    printf '%s' "$sid" >"$WDA_SESSION_FILE"
    printf '%s\n' "$sid"
}

viewport_height() {
    [ -n "$VIEWPORT_H" ] && { printf '%s' "$VIEWPORT_H"; return; }
    VIEWPORT_H=$(api "$WDA_URL/session/$(session_id)/window/size" | python3 -c '
import json, sys
try:
    print(int(json.load(sys.stdin)["value"]["height"]))
except Exception:
    print(667)')
    printf '%s' "$VIEWPORT_H"
}

find_by() {
    api -X POST "$WDA_URL/session/$(session_id)/element" \
        -H 'Content-Type: application/json' \
        -d "{\"using\":\"$1\",\"value\":\"$2\"}" \
        | python3 -c '
import json, sys
try:
    print(json.load(sys.stdin)["value"]["ELEMENT"])
except Exception:
    print("")'
}

# Centre of an element, or empty when it has no rect.
centre_of() {
    api "$WDA_URL/session/$(session_id)/element/$1/rect" | python3 -c '
import json, sys
try:
    v = json.load(sys.stdin)["value"]
    print(int(v["x"] + v["width"] / 2), int(v["y"] + v["height"] / 2))
except Exception:
    pass'
}

tap_xy() {
    api -X POST "$WDA_URL/session/$(session_id)/actions" \
        -H 'Content-Type: application/json' \
        -d "{\"actions\":[{\"type\":\"pointer\",\"id\":\"f1\",\"parameters\":{\"pointerType\":\"touch\"},\"actions\":[{\"type\":\"pointerMove\",\"duration\":0,\"x\":$1,\"y\":$2},{\"type\":\"pointerDown\",\"button\":0},{\"type\":\"pause\",\"duration\":80},{\"type\":\"pointerUp\",\"button\":0}]}]}" >/dev/null
}

# Drag the content by `dy` points (negative scrolls further down the list).
drag_by() {
    local h mid
    h=$(viewport_height)
    mid=$((h / 2))
    api -X POST "$WDA_URL/session/$(session_id)/actions" \
        -H 'Content-Type: application/json' \
        -d "{\"actions\":[{\"type\":\"pointer\",\"id\":\"f1\",\"parameters\":{\"pointerType\":\"touch\"},\"actions\":[{\"type\":\"pointerMove\",\"duration\":0,\"x\":180,\"y\":$mid},{\"type\":\"pointerDown\",\"button\":0},{\"type\":\"pointerMove\",\"duration\":500,\"x\":180,\"y\":$((mid + $1))},{\"type\":\"pointerUp\",\"button\":0}]}]}" >/dev/null
    sleep 1
}

# Scroll until `label` sits inside the viewport, then tap it.
#
# Re-reads the rect every iteration: the list re-renders as it scrolls and
# a rect captured before a drag is stale by the time it is used, which is
# what made a naive scroll-then-tap miss twice in a row.
tap_label() {
    local label="$1" h margin el coords x y attempt=0
    h=$(viewport_height)
    # Keep clear of the status bar and the floating command bar, either of
    # which will swallow a tap aimed at content underneath it.
    margin=90
    while [ "$attempt" -lt 8 ]; do
        el=$(find_by "predicate string" "label == '$label'")
        if [ -z "$el" ]; then
            echo "no element labelled '$label'" >&2
            return 1
        fi
        coords=$(centre_of "$el")
        if [ -z "$coords" ]; then
            echo "'$label' has no rect" >&2
            return 1
        fi
        read -r x y <<<"$coords"
        if [ "$y" -ge "$margin" ] && [ "$y" -le $((h - margin)) ]; then
            tap_xy "$x" "$y"
            echo "tapped '$label' at $x,$y"
            return 0
        fi
        # Above the top → drag content down; below the bottom → drag up.
        if [ "$y" -lt "$margin" ]; then drag_by 200; else drag_by -200; fi
        attempt=$((attempt + 1))
    done
    echo "'$label' never became reachable (last y=$y, viewport=$h)" >&2
    return 1
}

# Tap `label` where it already is, without scrolling.
#
# `tap_label` exists for content that scrolls; it refuses anything within
# 90pt of an edge because the status bar and the floating command bar
# swallow taps aimed underneath them. But the command bar's own buttons
# live inside that margin and are pinned there, so scrolling can never
# bring them anywhere else — `tap_label` drags eight times and gives up.
tap_fixed() {
    local label="$1" el coords x y
    el=$(find_by "predicate string" "label == '$label'")
    if [ -z "$el" ]; then
        echo "no element labelled '$label'" >&2
        return 1
    fi
    coords=$(centre_of "$el")
    if [ -z "$coords" ]; then
        echo "'$label' has no rect" >&2
        return 1
    fi
    read -r x y <<<"$coords"
    tap_xy "$x" "$y"
    echo "tapped '$label' at $x,$y"
}

accept_alert() {
    # Unscoped session: a permission alert is springboard's, and an
    # app-scoped session answers "not running, possibly crashed".
    local body sid
    body=$(api -X POST "$WDA_URL/session" -H 'Content-Type: application/json' \
        -d '{"capabilities":{"alwaysMatch":{"shouldWaitForQuiescence":false}}}')
    sid=$(printf '%s' "$body" | python3 -c '
import json, sys
try:
    print(json.load(sys.stdin)["value"].get("sessionId", ""))
except Exception:
    print("")')
    [ -z "$sid" ] && { echo "could not open an unscoped session" >&2; return 1; }
    api -X POST "$WDA_URL/session/$sid/alert/accept" \
        -H 'Content-Type: application/json' -d '{}' >/dev/null
    echo "alert accepted"
}

labels() {
    api "$WDA_URL/source?format=json" | python3 -c '
import json, sys
def walk(node):
    kind = node.get("type", "")
    label = node.get("label")
    if label and kind in ("Button", "StaticText", "Image"):
        rect = node.get("rect", {})
        print("%-11s %-40s y=%s" % (kind, str(label)[:40], rect.get("y")))
    for child in node.get("children", []):
        walk(child)
walk(json.load(sys.stdin)["value"])'
}

case "${1:-}" in
    session)      start_session "${2:-}" ;;
    tap-label)    [ $# -ge 2 ] || { echo "usage: $0 tap-label <label>" >&2; exit 2; }
                  tap_label "$2" ;;
    tap-fixed)    [ $# -ge 2 ] || { echo "usage: $0 tap-fixed <label>" >&2; exit 2; }
                  tap_fixed "$2" ;;
    tap-name)     [ $# -ge 2 ] || { echo "usage: $0 tap-name <name>" >&2; exit 2; }
                  el=$(find_by name "$2")
                  [ -z "$el" ] && { echo "no element named '$2'" >&2; exit 1; }
                  read -r x y <<<"$(centre_of "$el")"
                  tap_xy "$x" "$y"; echo "tapped '$2' at $x,$y" ;;
    labels)       labels ;;
    accept-alert) accept_alert ;;
    *)            echo "usage: $0 {session|tap-label|tap-fixed|tap-name|labels|accept-alert}" >&2; exit 2 ;;
esac
