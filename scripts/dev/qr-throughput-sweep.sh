#!/usr/bin/env bash
# SPDX-FileCopyrightText: 2026 Mattia Egloff <mattia.egloff@pm.me>
# SPDX-License-Identifier: GPL-3.0-or-later
#
# QR throughput optimization sweep — bidirectional
#
# Tests QR scanning throughput across payload sizes (V5-V10),
# display FPS, and error correction levels. Runs two passes:
#   Pass 1: Device A = beacon, Device B = scanner (rxing at 240p)
#   Pass 2: Device B = beacon, Device A = scanner (rxing at 240p)
#
# This mirrors the real exchange protocol where both devices
# simultaneously display and scan.
#
# Requires two Android devices connected via ADB.
# Usage: ./scripts/scripts/dev/qr-throughput-sweep.sh

set -euo pipefail

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m'

# ── Device Detection ──────────────────────────────────────────────
DEVICES=($(adb devices | grep -E '^\S+\s+device$' | awk '{print $1}'))
if [[ ${#DEVICES[@]} -lt 2 ]]; then
    echo -e "${RED}ERROR: Need 2 Android devices. Found ${#DEVICES[@]}.${NC}"
    adb devices -l
    exit 1
fi

DEV_A="${DEVICES[0]}"
DEV_B="${DEVICES[1]}"
MODEL_A=$(adb -s "$DEV_A" shell getprop ro.product.model | tr -d '\r')
MODEL_B=$(adb -s "$DEV_B" shell getprop ro.product.model | tr -d '\r')

echo -e "${BLUE}═══════════════════════════════════════════════════════${NC}"
echo -e "${BLUE}  QR Throughput Sweep — Bidirectional${NC}"
echo -e "${BLUE}═══════════════════════════════════════════════════════${NC}"
echo ""
echo -e "  Device A: ${YELLOW}$MODEL_A${NC} ($DEV_A)"
echo -e "  Device B: ${YELLOW}$MODEL_B${NC} ($DEV_B)"
echo ""

# ── Config ────────────────────────────────────────────────────────
BEACON_ACT="app.vauchi/.diagnostic.qr.QrBeaconActivity"
TUNER_ACT="app.vauchi/.diagnostic.qr.QrTunerActivity"
APP_PKG="app.vauchi"
DURATION=15  # seconds per measurement

# Timestamp & output
TIMESTAMP=$(date -u +%Y%m%d-%H%M%S)
RESULTS_DIR="/tmp/qr-throughput-$TIMESTAMP"
mkdir -p "$RESULTS_DIR"

# ── Test Matrix ───────────────────────────────────────────────────
# Payload sizes → approximate QR versions (alphanumeric mode):
#   100B → V5,  150B → V6,  200B → V7
#   300B → V8,  400B → V9,  600B → V10

PAYLOAD_SIZES=(100 150 200 300 400 600)
FPS_RATES=(5 8 10 15)
BG="gray"  # gray matches exchange protocol colors

TOTAL=$(( ${#PAYLOAD_SIZES[@]} * ${#FPS_RATES[@]} ))
echo -e "${YELLOW}Test matrix per pass:${NC}"
echo "  Payloads:  ${PAYLOAD_SIZES[*]} bytes (≈ V5-V10)"
echo "  FPS rates: ${FPS_RATES[*]}"
echo "  BG:        $BG (exchange protocol colors)"
echo "  Scanner:   rxing (rqrr_raw) at 240p front camera"
echo "  Duration:  ${DURATION}s per config"
echo "  Configs:   $TOTAL per pass × 2 passes = $((TOTAL * 2)) total"
echo ""

# ── Helpers ───────────────────────────────────────────────────────
stop_app() {
    adb -s "$1" shell am force-stop "$APP_PKG" 2>/dev/null || true
}

start_beacon() {
    local serial="$1" size="$2" fps="$3"
    adb -s "$serial" shell am start -n "$BEACON_ACT" \
        --es mode throughput --ei fps "$fps" --es bg "$BG" \
        --ei data_size "$size" --ei total_kb 50 > /dev/null 2>&1
}

start_rxing_scanner() {
    local serial="$1" duration="$2"
    adb -s "$serial" shell am start -n "$TUNER_ACT" \
        --es test rxing-throughput \
        --ei duration "$duration" \
        --es resolution 240p \
        --es scanner rqrr_raw \
        --es camera front > /dev/null 2>&1
}

wait_scanner_done() {
    local serial="$1" max_wait="$2"
    local elapsed=0
    while [[ $elapsed -lt $max_wait ]]; do
        local active
        active=$(adb -s "$serial" shell dumpsys activity activities 2>/dev/null \
            | grep -c "QrTunerActivity" || true)
        if [[ "$active" -eq 0 ]]; then
            return 0
        fi
        sleep 2
        elapsed=$((elapsed + 2))
    done
    return 1
}

collect_logcat() {
    local serial="$1" tag="$2" dest="$3"
    adb -s "$serial" shell logcat -d -s "$tag" 2>/dev/null \
        | grep -E "Throughput|TTFD|Unique|Decodes|latency|Resolution|Results" \
        > "$dest" 2>/dev/null || true
}

pull_results() {
    local serial="$1" dest="$2"
    adb -s "$serial" pull /storage/emulated/0/Android/data/app.vauchi/files/ \
        "$dest" 2>/dev/null || true
}

# ── Prepare Devices ───────────────────────────────────────────────
echo -e "${YELLOW}Preparing devices...${NC}"
# Set brightness to 65% (≈166/255) to match exchange protocol
for dev in "$DEV_A" "$DEV_B"; do
    adb -s "$dev" shell settings put system screen_brightness 166 2>/dev/null || true
    adb -s "$dev" shell settings put system screen_off_timeout 600000 2>/dev/null || true
    # Clear old logcat
    adb -s "$dev" shell logcat -c 2>/dev/null || true
done

echo ""
echo -e "${CYAN}╔══════════════════════════════════════════════════════╗${NC}"
echo -e "${CYAN}║  Position devices face-to-face, screens pointing    ║${NC}"
echo -e "${CYAN}║  at each other (front cameras seeing other screen)  ║${NC}"
echo -e "${CYAN}║  Distance: ~15-25cm (typical exchange distance)     ║${NC}"
echo -e "${CYAN}╚══════════════════════════════════════════════════════╝${NC}"
echo ""
echo -e "Press Enter when devices are positioned..."
read -r

# ── Pass 1: A=beacon, B=scanner ───────────────────────────────────
run_pass() {
    local pass_num="$1" beacon_serial="$2" scanner_serial="$3"
    local beacon_model scanner_model
    beacon_model=$(adb -s "$beacon_serial" shell getprop ro.product.model | tr -d '\r')
    scanner_model=$(adb -s "$scanner_serial" shell getprop ro.product.model | tr -d '\r')

    local pass_dir="$RESULTS_DIR/pass${pass_num}"
    mkdir -p "$pass_dir"

    echo -e "${GREEN}═══════════════════════════════════════════════════${NC}"
    echo -e "${GREEN}  Pass $pass_num: $beacon_model → $scanner_model${NC}"
    echo -e "${GREEN}  Beacon=$beacon_model | Scanner=$scanner_model${NC}"
    echo -e "${GREEN}═══════════════════════════════════════════════════${NC}"
    echo ""

    local config_num=0
    local csv="$pass_dir/results.csv"
    echo "config,payload_bytes,fps,beacon,scanner,ttfd_ms,decodes_per_sec,unique_qrs_per_sec,bytes_per_sec,avg_latency_ms" > "$csv"

    for size in "${PAYLOAD_SIZES[@]}"; do
        for fps in "${FPS_RATES[@]}"; do
            config_num=$((config_num + 1))
            local label="${size}B@${fps}fps"
            echo -ne "  ${BLUE}[$config_num/$TOTAL]${NC} $label "

            # Clear logcat for clean capture
            adb -s "$scanner_serial" shell logcat -c 2>/dev/null || true

            # Start beacon
            start_beacon "$beacon_serial" "$size" "$fps"
            sleep 3  # let beacon settle

            # Start scanner
            start_rxing_scanner "$scanner_serial" "$DURATION"

            # Wait for scanner to complete (duration + 10s margin)
            local max_wait=$((DURATION + 15))
            if wait_scanner_done "$scanner_serial" "$max_wait"; then
                # Capture results from logcat
                local logfile="$pass_dir/log-${config_num}-${label}.txt"
                collect_logcat "$scanner_serial" "Vauchi" "$logfile"

                # Extract key metrics from logcat
                local throughput decodes_per_s ttfd latency unique_qrs
                throughput=$(grep -oE 'THROUGHPUT: [0-9]+' "$logfile" 2>/dev/null | tail -1 | grep -oE '[0-9]+' || echo "0")
                decodes_per_s=$(grep -oE 'Decodes/s: [0-9.]+' "$logfile" 2>/dev/null | tail -1 | grep -oE '[0-9.]+' || echo "0")
                ttfd=$(grep -oE 'TTFD: -?[0-9]+' "$logfile" 2>/dev/null | tail -1 | grep -oE '-?[0-9]+' || echo "-1")
                latency=$(grep -oE 'Avg decode latency: [0-9.]+' "$logfile" 2>/dev/null | tail -1 | grep -oE '[0-9.]+' || echo "0")
                unique_qrs=$(grep -oE 'unique_qrs_per_sec.*?[0-9.]+' "$logfile" 2>/dev/null | tail -1 | grep -oE '[0-9.]+$' || echo "0")

                echo -e "→ ${GREEN}${throughput} B/s${NC} | ${decodes_per_s}/s | TTFD=${ttfd}ms | lat=${latency}ms"
                echo "$config_num,$size,$fps,$beacon_model,$scanner_model,$ttfd,$decodes_per_s,$unique_qrs,$throughput,$latency" >> "$csv"
            else
                echo -e "→ ${RED}TIMEOUT${NC}"
                echo "$config_num,$size,$fps,$beacon_model,$scanner_model,-1,0,0,0,0" >> "$csv"
                stop_app "$scanner_serial"
            fi

            # Stop beacon
            stop_app "$beacon_serial"
            sleep 1
        done
    done

    # Pull JSON results
    pull_results "$scanner_serial" "$pass_dir/json-results/"

    echo ""
    echo -e "${GREEN}Pass $pass_num complete. Results: $pass_dir/results.csv${NC}"
    echo ""
}

# ── Execute Both Passes ───────────────────────────────────────────
run_pass 1 "$DEV_A" "$DEV_B"

echo -e "${CYAN}Swapping roles for Pass 2...${NC}"
echo ""

run_pass 2 "$DEV_B" "$DEV_A"

# ── Summary ───────────────────────────────────────────────────────
echo -e "${GREEN}═══════════════════════════════════════════════════════${NC}"
echo -e "${GREEN}  All passes complete!${NC}"
echo -e "${GREEN}═══════════════════════════════════════════════════════${NC}"
echo ""
echo -e "Results: ${YELLOW}$RESULTS_DIR${NC}"
echo ""
echo "  Pass 1 (${MODEL_A}→${MODEL_B}): $RESULTS_DIR/pass1/results.csv"
echo "  Pass 2 (${MODEL_B}→${MODEL_A}): $RESULTS_DIR/pass2/results.csv"
echo ""

# Print top configs from each pass
for pass in 1 2; do
    csv="$RESULTS_DIR/pass${pass}/results.csv"
    if [[ -f "$csv" ]]; then
        echo -e "${BLUE}Top 5 configs (Pass $pass — by throughput B/s):${NC}"
        tail -n +2 "$csv" | sort -t, -k9 -rn | head -5 | while IFS=, read -r cfg sz fp bm sm ttfd dps uqps bps lat; do
            echo "  ${sz}B @ ${fp}fps: ${bps} B/s (${dps} dec/s, TTFD=${ttfd}ms, lat=${lat}ms)"
        done
        echo ""
    fi
done
