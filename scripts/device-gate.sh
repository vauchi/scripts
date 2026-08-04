#!/usr/bin/env bash
# SPDX-FileCopyrightText: 2026 Mattia Egloff <mattia.egloff@pm.me>
#
# SPDX-License-Identifier: GPL-3.0-or-later

# device-gate.sh — Real-device usability gate.
#
# Proves "a user can use the app" on PHYSICAL hardware and writes
# machine-readable evidence. Per platform:
#   1. detect a physical device (reuses just/device-test-lib.sh;
#      honors IOS_DEVICE_ID / ANDROID_SERIAL overrides)
#   2. ABI parity check (scripts/scripts/check-binding-abi.sh;
#      skipped with --skip-build)
#   3. build + install via `just rebuild-ios` / `just rebuild-android`
#      (signing/keychain handled inside those recipes — this script
#      never touches the keychain password itself; skipped with
#      --skip-build)
#   4. run the critical Maestro flows sequentially
#      (`maestro --device <udid> test`), per-flow timeout, per-flow log
#      (Linux runs the real-session AT-SPI suite instead)
#   5. evidence: per-flow logs, best-effort per-flow screenshots
#      (`just dt-screenshot-ios/android`), and result.json under
#      _private/docs/testing/device-gates/<YYYY-MM-DD>/<platform>/
#   6. exit non-zero if any flow fails; print a final summary table
#
# Usage:
#   device-gate.sh <ios|android|linux|all> [--skip-build] [--flows "a,b,c"]
#
# Options:
#   --skip-build      Skip ABI parity check and build+install; run the
#                     flows against whatever is already installed.
#   --flows "a,b,c"   Comma-separated Maestro flow names. Default:
#                     create_identity,add_field,generate_qr,sync,add_custom_group
#                     complete_exchange is NOT in the default set (it needs
#                     two devices); naming it here attempts it and records
#                     the result.
#
# Environment:
#   IOS_DEVICE_ID   iOS device UDID override
#   ANDROID_SERIAL  Android device serial override
#   FLOW_TIMEOUT    Per-flow timeout in seconds (default: 300)
#   PIN             App PIN for PIN-gated flows (default: 123456, same
#                   convention as _private/docs/testing/device-automation/
#                   vauchi-gui-test.sh)
#   NAME, FIELD_TYPE, FIELD_LABEL, FIELD_VALUE, QR_DATA, ... — Maestro flow
#                   parameters; defaults mirror `just e2e-maestro-critical`
#
# Exit codes: 0 = every flow passed, 1 = a flow/gate step failed,
#             2 = usage error.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WORKSPACE_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
cd "$WORKSPACE_ROOT"

# shellcheck source=just/device-test-lib.sh
source "just/device-test-lib.sh"

RUN_DATE="$(date +%F)"
EVIDENCE_BASE="_private/docs/testing/device-gates/$RUN_DATE"
FLOW_TIMEOUT="${FLOW_TIMEOUT:-300}"
PIN="${PIN:-123456}"

DEFAULT_FLOWS=(create_identity add_field generate_qr sync add_custom_group)

PLATFORM=""
SKIP_BUILD=0
FLOWS_CSV=""
FLOWS_EXPLICIT=0
MAESTRO=""
LAST_EVIDENCE_DIR=""
OVERALL_RC=0
SUMMARY=()

usage() {
    # Print the doc-comment block (from the title line through the
    # exit-codes paragraph) with the "# " prefix stripped.
    sed -n 's/^# \{0,1\}//p' "${BASH_SOURCE[0]}" \
        | awk '/^device-gate.sh — Real-device usability gate\./,/usage error\./'
}

# Portable timeout: GNU timeout (Linux), gtimeout (macOS coreutils),
# or a background watchdog as last resort. Exit code is the command's;
# 124/137/143 indicate a timeout kill.
run_with_timeout() {
    local secs="$1"; shift
    if command -v timeout >/dev/null 2>&1; then
        timeout "$secs" "$@"
        return
    fi
    if command -v gtimeout >/dev/null 2>&1; then
        gtimeout "$secs" "$@"
        return
    fi
    "$@" &
    local pid=$!
    (
        sleep "$secs"
        kill -TERM "$pid" 2>/dev/null || true
    ) &
    local watchdog=$!
    local rc=0
    wait "$pid" || rc=$?
    kill "$watchdog" 2>/dev/null || true
    wait "$watchdog" 2>/dev/null || true
    return "$rc"
}

classify_rc() {
    case "$1" in
        0)           echo pass ;;
        124|137|143) echo timeout ;;
        *)           echo fail ;;
    esac
}

# ── Device detection (wraps just/device-test-lib.sh) ──────────────

detect_device() {
    local platform="$1"
    local id
    case "$platform" in
        ios)
            if id=$(dt_detect_ios_device); then
                printf '%s\n' "$id"
                return 0
            fi
            {
                printf '%b\n' "${RED}ERROR: no physical iOS device detected.${NC}"
                echo "Probed (in order):"
                echo "  1. IOS_DEVICE_ID env override — ${IOS_DEVICE_ID:-<unset>}"
                echo "  2. pymobiledevice3 usbmux list"
                echo "  3. xcrun devicectl list devices (non-Simulator UDID)"
                echo "  4. system_profiler SPUSBDataType (iPhone/iPad serial)"
                echo "Connect an iPhone/iPad via USB and trust this computer, or set IOS_DEVICE_ID."
            } >&2
            return 1
            ;;
        android)
            if id=$(dt_detect_android_device); then
                printf '%s\n' "$id"
                return 0
            fi
            {
                printf '%b\n' "${RED}ERROR: no physical Android device detected.${NC}"
                echo "Probed (in order):"
                echo "  1. ANDROID_SERIAL env override — ${ANDROID_SERIAL:-<unset>}"
                echo "  2. adb devices (first entry in 'device' state)"
                echo "Connect an Android device via USB with USB debugging enabled, or set ANDROID_SERIAL."
            } >&2
            return 1
            ;;
    esac
}

# ── Gate steps ────────────────────────────────────────────────────

abi_check() {
    local platform="$1"
    local artifact bindings
    case "$platform" in
        ios)
            # Same artifact/bindings paths as `just _dt-package-ios`.
            local core_dir
            core_dir=$(dt_resolve_core_dir "")
            artifact="$core_dir/target/aarch64-apple-ios/release/libvauchi_platform.a"
            bindings="$core_dir/target/bindings/ios/generated/vauchi_platform.swift"
            ;;
        android)
            # Same artifact/bindings paths as `just _dt-package-android`.
            artifact="android/app/src/main/jniLibs/arm64-v8a/libvauchi_platform.so"
            bindings="android/app/src/local-bindings/kotlin/uniffi/vauchi_platform/vauchi_platform.kt"
            ;;
    esac
    if [[ ! -f "$artifact" || ! -f "$bindings" ]]; then
        echo "  ABI parity: artifacts not present yet — deferred to the build's internal gate."
        return 0
    fi
    echo "  ABI parity: checking $platform bindings vs $(basename "$artifact")..."
    scripts/scripts/check-binding-abi.sh \
        --platform "$platform" \
        --artifact "$artifact" \
        --bindings "$bindings"
}

require_maestro() {
    if command -v maestro >/dev/null 2>&1; then
        MAESTRO="maestro"
    elif [[ -x "$HOME/.maestro/bin/maestro" ]]; then
        MAESTRO="$HOME/.maestro/bin/maestro"
    else
        printf '%b\n' "${RED}ERROR: Maestro CLI not found (PATH or ~/.maestro/bin/maestro).${NC}" >&2
        echo "Run 'just maestro-setup' for install instructions." >&2
        return 1
    fi
}

validate_flows() {
    local platform="$1"
    local name flow
    for name in "${FLOWS[@]}"; do
        flow="e2e/maestro/$platform/$name.yaml"
        if [[ ! -f "$flow" ]]; then
            printf '%b\n' "${RED}ERROR: flow not found: $flow${NC}" >&2
            echo "Available $platform flows:" >&2
            find "e2e/maestro/$platform" -name '*.yaml' -exec basename {} .yaml \; | sort | sed 's/^/  /' >&2
            return 1
        fi
    done
}

capture_screenshot() {
    local platform="$1" out="$2"
    case "$platform" in
        ios)     just dt-screenshot-ios "$out" ;;
        android) just dt-screenshot-android "$out" ;;
    esac
}

write_result_json() {
    local platform="$1" device="$2" overall="$3" out="$4"
    shift 4
    local entries=("$@")   # each "name|status|duration_s"
    {
        printf '{\n'
        printf '  "platform": "%s",\n' "$platform"
        printf '  "date": "%s",\n' "$RUN_DATE"
        printf '  "device": "%s",\n' "$device"
        printf '  "flows": [\n'
        local i name status dur rest count=${#entries[@]}
        for i in "${!entries[@]}"; do
            name="${entries[$i]%%|*}"
            rest="${entries[$i]#*|}"
            status="${rest%%|*}"
            dur="${rest#*|}"
            printf '    {"name": "%s", "status": "%s", "duration_s": %s}' "$name" "$status" "$dur"
            if [[ "$i" -lt $((count - 1)) ]]; then
                printf ','
            fi
            printf '\n'
        done
        printf '  ],\n'
        printf '  "overall": "%s"\n' "$overall"
        printf '}\n'
    } > "$out"
}

# ── Platform gates ────────────────────────────────────────────────

# Wake + unlock an Android device for the flow run.
# Order matters: stayon first (keeps USB-connected device awake), then
# wakeup, swipe-up to the PIN pad, enter the PIN as digit keycodes
# (input text can miss non-IME PIN pads), tap the confirm arrow
# (KEYEVENT_ENTER does not submit on AOSP PIN pads — found 2026-07-18).
ensure_android_ready() {
    local serial="$1"
    local adb=(adb -s "$serial")
    local attempt
    "${adb[@]}" shell svc power stayon usb >/dev/null 2>&1 || true
    # Keep the screen on for the whole gate run (test device).
    "${adb[@]}" shell settings put system screen_off_timeout 600000 >/dev/null 2>&1 || true
    for attempt in 1 2; do
        "${adb[@]}" shell input keyevent KEYEVENT_WAKEUP >/dev/null 2>&1
        sleep 2
        # Already unlocked? (keyguard not the FOCUSED window — a bare
        # NotificationShade grep also matches its always-present window)
        if ! "${adb[@]}" shell dumpsys window 2>/dev/null | grep mCurrentFocus | grep -q "NotificationShade"; then
            echo "  Android device awake + unlocked"
            return 0
        fi
        "${adb[@]}" shell input swipe 540 1900 540 500 400 >/dev/null 2>&1
        sleep 2
        # PIN digits as keycodes (KEYCODE_0=7 … KEYCODE_9=16)
        local d
        for ((i = 0; i < ${#PIN}; i++)); do
            d="${PIN:i:1}"
            "${adb[@]}" shell input keyevent $((7 + d)) >/dev/null 2>&1
            sleep 0.2
        done
        sleep 1
        "${adb[@]}" shell input tap 875 1620 >/dev/null 2>&1   # PIN-pad confirm arrow (1080x2220)
        sleep 2
        if ! "${adb[@]}" shell dumpsys window 2>/dev/null | grep mCurrentFocus | grep -q "NotificationShade"; then
            echo "  Android device woken + unlocked (PIN)"
            return 0
        fi
        echo "  Android unlock attempt $attempt failed — retrying..."
    done
    return 1
}

gate_mobile() {
    local platform="$1"   # ios | android
    local evidence_dir="$EVIDENCE_BASE/$platform"
    LAST_EVIDENCE_DIR="$evidence_dir"
    mkdir -p "$evidence_dir"
    printf '%b\n' "${YELLOW}═══ Device gate: $platform ═══${NC}"

    if ! command -v just >/dev/null 2>&1; then
        printf '%b\n' "${RED}ERROR: 'just' not found in PATH.${NC}" >&2
        write_result_json "$platform" "" fail "$evidence_dir/result.json"
        return 1
    fi

    # (1) Detect physical device
    local device
    if ! device=$(detect_device "$platform"); then
        write_result_json "$platform" "" fail "$evidence_dir/result.json"
        return 1
    fi
    echo "  Device: $device"

    # (2) + (3) ABI parity, build + install
    if [[ "$SKIP_BUILD" -eq 0 ]]; then
        if ! abi_check "$platform"; then
            printf '%b\n' "${RED}ERROR: ABI parity check failed for $platform.${NC}" >&2
            write_result_json "$platform" "$device" fail "$evidence_dir/result.json"
            return 1
        fi
        local recipe="rebuild-$platform"
        echo "  Build+install: just $recipe"
        if ! just "$recipe"; then
            printf '%b\n' "${RED}ERROR: 'just $recipe' failed — see output above.${NC}" >&2
            write_result_json "$platform" "$device" fail "$evidence_dir/result.json"
            return 1
        fi
    else
        echo "  ABI parity + build+install: SKIPPED (--skip-build)"
    fi

    if ! require_maestro; then
        write_result_json "$platform" "$device" fail "$evidence_dir/result.json"
        return 1
    fi

    # (3b) Android precondition: wake + unlock. A locked/dozing device
    # makes every flow fail with black screenshots (found 2026-07-18:
    # flows red while logcat showed the app healthy behind the keyguard).
    # iOS has no adb-equivalent input path — the phone must be unlocked
    # manually (documented device-test precondition).
    if [[ "$platform" == "android" ]]; then
        ensure_android_ready "$device" || {
            printf '%b\n' "${RED}ERROR: could not wake/unlock Android device $device (PIN=$PIN).${NC}" >&2
            write_result_json "$platform" "$device" fail "$evidence_dir/result.json"
            return 1
        }
    fi
    if ! validate_flows "$platform"; then
        write_result_json "$platform" "$device" fail "$evidence_dir/result.json"
        return 1
    fi

    # Maestro 2.x does not inherit arbitrary shell env vars; pass flow
    # parameters explicitly via --env. Defaults mirror `just e2e-maestro-critical`
    # (NAME/FIELD_*) and `just e2e-maestro` (the rest) so custom --flows work.
    local maestro_env=(
        --env "NAME=${NAME:-E2E Test}"
        --env "FIELD_TYPE=${FIELD_TYPE:-Email}"
        --env "FIELD_LABEL=${FIELD_LABEL:-Work}"
        --env "FIELD_VALUE=${FIELD_VALUE:-test@example.com}"
        --env "APP_PASSWORD=${APP_PASSWORD:-TestPass123!}"
        --env "DURESS_PIN=${DURESS_PIN:-654321}"
        --env "DECOY_NAME=${DECOY_NAME:-Decoy Contact}"
        --env "REAL_CONTACT_NAME=${REAL_CONTACT_NAME:-E2E Test}"
        --env "CONTACT_NAME=${CONTACT_NAME:-E2E Test}"
        --env "LABEL_NAME=${LABEL_NAME:-VIP}"
        --env "ALERT_MESSAGE=${ALERT_MESSAGE:-Emergency alert test}"
        --env "QR_DATA=${QR_DATA:-vauchi://exchange#test}"
        --env "PIN=${PIN}"
    )

    # (4) Run flows sequentially
    local -a results=()
    local pfail=0
    local name flow log png start rc dur status
    for name in "${FLOWS[@]}"; do
        # Re-verify wake/unlock before EACH flow — a long chain can
        # outlast the screen timeout and the maestro driver dies with
        # gRPC UNAVAILABLE errors (found 2026-07-18 extended run).
        if [[ "$platform" == "android" ]]; then
            ensure_android_ready "$device" || {
                printf '%b\n' "${RED}ERROR: Android device re-locked mid-run.${NC}" >&2
                pfail=1
                results+=("$name|fail|0")
                continue
            }
        fi
        flow="e2e/maestro/$platform/$name.yaml"
        log="$evidence_dir/$name.log"
        png="$evidence_dir/$name.png"
        echo "  → $name (timeout ${FLOW_TIMEOUT}s)"
        start=$SECONDS
        rc=0
        # iOS on physical hardware needs the xctestrunner driver signed:
        # --apple-team-id (default: the Vauchi dev team) and a generous
        # driver-startup timeout on first run (driver install + trust).
        local -a platform_args=()
        if [[ "$platform" == "ios" ]]; then
            platform_args+=(--apple-team-id "${APPLE_TEAM_ID:-L2853TNSJ4}")
            export MAESTRO_DRIVER_STARTUP_TIMEOUT="${MAESTRO_DRIVER_STARTUP_TIMEOUT:-240000}"
        fi
        # Keep the expanded array non-empty under macOS Bash 3.2 with
        # `set -u`; expanding a declared-but-empty array aborts the Android
        # gate before Maestro starts.
        platform_args+=("$flow")
        platform_args+=("${maestro_env[@]}")
        run_with_timeout "$FLOW_TIMEOUT" "$MAESTRO" \
            --device "$device" test \
            "${platform_args[@]}" >"$log" 2>&1 || rc=$?
        # Android driver self-heal: a dead driver (gRPC UNAVAILABLE)
        # means the run is invalid, not a red flow — restart + retry once
        # with --reinstall-driver (failed sessions can uninstall the APK).
        if [[ "$platform" == "android" && $rc -ne 0 ]] && \
           grep -qE "UNAVAILABLE|Connection refused" "$log"; then
            echo "    maestro driver died — reinstalling, retrying once"
            rc=0
            start=$SECONDS
            run_with_timeout "$FLOW_TIMEOUT" "$MAESTRO" \
                --device "$device" test \
                --reinstall-driver \
                "${platform_args[@]}" >"$log" 2>&1 || rc=$?
        fi
        # iOS driver self-heal: the xctrunner dies mid-run under load
        # (signature: "Failed to connect to /127.0.0.1:7001"; launchd
        # reports the runner terminated, then installcoordinationd
        # reinstalls it — observed 2026-07-18 in long sim chains). A
        # dead driver invalidates the run, not the flow — retry once
        # with --reinstall-driver, same as the Android heal above.
        if [[ "$platform" == "ios" && $rc -ne 0 ]] && \
           grep -qE "Failed to connect|Connection refused|:7001" "$log"; then
            echo "    maestro driver died — reinstalling, retrying once"
            rc=0
            start=$SECONDS
            run_with_timeout "$FLOW_TIMEOUT" "$MAESTRO" \
                --device "$device" test \
                --reinstall-driver \
                "${platform_args[@]}" >"$log" 2>&1 || rc=$?
        fi
        dur=$((SECONDS - start))
        status=$(classify_rc "$rc")
        if [[ "$status" != "pass" ]]; then
            pfail=1
        fi
        echo "    $status (${dur}s) — $log"
        results+=("$name|$status|$dur")
        # (5) Best-effort screenshot — evidence only, never gate-relevant.
        if ! capture_screenshot "$platform" "$png" >>"$log" 2>&1; then
            echo "    (screenshot unavailable — tolerated)"
        fi
    done

    local overall=pass
    if [[ "$pfail" -ne 0 ]]; then
        overall=fail
    fi
    write_result_json "$platform" "$device" "$overall" "$evidence_dir/result.json" "${results[@]}"
    echo "  Evidence: $evidence_dir"
    if [[ "$overall" == "pass" ]]; then
        printf '%b\n' "  ${GREEN}Result: PASS${NC}"
        return 0
    fi
    printf '%b\n' "  ${RED}Result: FAIL${NC}"
    return 1
}

gate_ios()     { gate_mobile ios; }
gate_android() { gate_mobile android; }

gate_linux() {
    local evidence_dir="$EVIDENCE_BASE/linux"
    LAST_EVIDENCE_DIR="$evidence_dir"
    printf '%b\n' "${YELLOW}═══ Device gate: linux (real-session AT-SPI) ═══${NC}"

    # Real-session only: the gate proves usability in the user's actual
    # session, so it refuses the Xvfb fallback run-tests.sh would take.
    if [[ -z "${DISPLAY:-}" && -z "${WAYLAND_DISPLAY:-}" ]]; then
        {
            printf '%b\n' "${RED}ERROR: linux gate requires a REAL graphical session.${NC}"
            echo "DISPLAY and WAYLAND_DISPLAY are both unset."
            echo "Run from the machine's graphical session, or export DISPLAY"
            echo "over SSH (e.g. DISPLAY=:0) pointing at the live session."
        } >&2
        mkdir -p "$evidence_dir"
        write_result_json linux "$(hostname)" fail "$evidence_dir/result.json"
        return 1
    fi

    mkdir -p "$evidence_dir"
    if [[ "$FLOWS_EXPLICIT" -eq 1 ]]; then
        echo "  note: --flows applies to mobile platforms only; linux runs the AT-SPI suite."
    fi

    local log="$evidence_dir/atspi.log"
    echo "  Session: DISPLAY=${DISPLAY:-—} WAYLAND_DISPLAY=${WAYLAND_DISPLAY:-—}"
    echo "  → atspi (timeout ${FLOW_TIMEOUT}s)"
    local start=$SECONDS
    local rc=0
    # Same invocation as `just test-atspi-gtk`.
    run_with_timeout "$FLOW_TIMEOUT" \
        bash linux-gtk/tests/atspi/run-tests.sh -v --tb=short -k "not test_snapshots" \
        >"$log" 2>&1 || rc=$?
    local dur=$((SECONDS - start))
    local status
    status=$(classify_rc "$rc")
    echo "    $status (${dur}s) — $log"
    echo "    (screenshots not captured in linux mode)"

    local overall=pass
    if [[ "$status" != "pass" ]]; then
        overall=fail
    fi
    write_result_json linux "$(hostname)" "$overall" "$evidence_dir/result.json" "atspi|$status|$dur"
    echo "  Evidence: $evidence_dir"
    if [[ "$overall" == "pass" ]]; then
        printf '%b\n' "  ${GREEN}Result: PASS${NC}"
        return 0
    fi
    printf '%b\n' "  ${RED}Result: FAIL${NC}"
    return 1
}

# ── Argument parsing ──────────────────────────────────────────────

while [[ $# -gt 0 ]]; do
    case "$1" in
        ios|android|linux|all)
            if [[ -n "$PLATFORM" ]]; then
                echo "ERROR: platform given twice ('$PLATFORM' and '$1')" >&2
                exit 2
            fi
            PLATFORM="$1"
            ;;
        --skip-build)
            SKIP_BUILD=1
            ;;
        --flows)
            if [[ $# -lt 2 ]]; then
                echo "ERROR: --flows requires a value" >&2
                exit 2
            fi
            FLOWS_CSV="$2"
            shift
            ;;
        --flows=*)
            FLOWS_CSV="${1#*=}"
            ;;
        -h|--help)
            usage
            exit 0
            ;;
        *)
            echo "ERROR: unknown argument: $1" >&2
            echo "" >&2
            usage >&2
            exit 2
            ;;
    esac
    shift
done

if [[ -z "$PLATFORM" ]]; then
    usage >&2
    exit 2
fi

if [[ ! "$FLOW_TIMEOUT" =~ ^[0-9]+$ ]]; then
    echo "ERROR: FLOW_TIMEOUT must be a positive integer (got '$FLOW_TIMEOUT')" >&2
    exit 2
fi

FLOWS=()
if [[ -n "$FLOWS_CSV" ]]; then
    FLOWS_EXPLICIT=1
    # Tolerate "a, b, c" spacing.
    IFS=',' read -ra FLOWS <<< "${FLOWS_CSV// /}"
else
    FLOWS=("${DEFAULT_FLOWS[@]}")
fi

for f in "${FLOWS[@]}"; do
    if [[ ! "$f" =~ ^[a-z0-9_]+$ ]]; then
        echo "ERROR: invalid flow name '$f' (expected [a-z0-9_]+)" >&2
        exit 2
    fi
    if [[ "$f" == "complete_exchange" ]]; then
        echo "note: complete_exchange needs a second device's QR payload (QR_DATA env);"
        echo "      it is excluded from the default set and runs only because --flows named it."
    fi
done

# ── Dispatch ──────────────────────────────────────────────────────

printf '%b\n' "${YELLOW}Device gate — $RUN_DATE — platform: $PLATFORM${NC}"
if [[ "$SKIP_BUILD" -eq 1 ]]; then
    echo "(--skip-build: using apps already installed on the devices)"
fi
echo ""

run_one() {
    local p="$1"
    local rc=0
    case "$p" in
        ios)     gate_ios     || rc=$? ;;
        android) gate_android || rc=$? ;;
        linux)   gate_linux   || rc=$? ;;
    esac
    if [[ "$rc" -eq 0 ]]; then
        SUMMARY+=("$(printf '%-8s %-4s %s' "$p" PASS "$LAST_EVIDENCE_DIR")")
    else
        SUMMARY+=("$(printf '%-8s %-4s %s' "$p" FAIL "$LAST_EVIDENCE_DIR")")
        OVERALL_RC=1
    fi
    echo ""
}

case "$PLATFORM" in
    ios|android|linux)
        run_one "$PLATFORM"
        ;;
    all)
        run_one ios
        run_one android
        if [[ -n "${DISPLAY:-}" || -n "${WAYLAND_DISPLAY:-}" ]]; then
            run_one linux
        else
            echo "Skipping linux: DISPLAY/WAYLAND_DISPLAY unset (real session required)."
            echo ""
            SUMMARY+=("$(printf '%-8s %-4s %s' linux SKIP '-')")
        fi
        ;;
esac

# ── Summary ───────────────────────────────────────────────────────

printf '%b\n' "${YELLOW}═══ Device Gate Summary — $RUN_DATE ═══${NC}"
printf '  %-8s %-4s %s\n' PLATFORM RESULT EVIDENCE
for line in "${SUMMARY[@]}"; do
    printf '  %s\n' "$line"
done
echo ""

if [[ "$OVERALL_RC" -eq 0 ]]; then
    printf '%b\n' "${GREEN}DEVICE GATE: PASS${NC}"
else
    printf '%b\n' "${RED}DEVICE GATE: FAIL${NC}"
fi
exit "$OVERALL_RC"
