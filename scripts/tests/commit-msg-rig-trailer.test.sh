#!/usr/bin/env bash
# SPDX-FileCopyrightText: 2026 Mattia Egloff <mattia.egloff@pm.me>
#
# SPDX-License-Identifier: GPL-3.0-or-later
#
# Sentinel suite for scripts/hooks/commit-msg — VGT13: a feat:, fix: or
# refactor: commit that changes how exchange codes are read or drawn says
# how it ran on the rig at both ends of 7–14 cm, with a `Rig:` trailer.
# Rule page: _private/docs/lint-errors/vgt13-rig-trailer.md
set -u

HOOKS_DIR="$(cd "$(dirname "$0")/../../hooks" && pwd)"
HOOK="$HOOKS_DIR/commit-msg"
pass=0
fail=0
fail_index_read=false

assert_eq() {
    name="$1"; want="$2"; got="$3"
    if [ "$want" = "$got" ]; then
        pass=$((pass + 1)); printf '  PASS %s\n' "$name"
    else
        fail=$((fail + 1))
        printf '  FAIL %s\n    want: %s\n    got:  %s\n' "$name" "$want" "$got" >&2
    fi
}

# Each case runs the hook inside a throwaway repo named like the real
# one, with the given paths staged.
run_case() { # $1=repo name  $2=message  $3..=paths to stage → sets rc, out
    name="$1"; msg="$2"; shift 2
    parent="$(mktemp -d)"
    repo="$parent/$name"
    mkdir -p "$repo"
    git -C "$repo" init -q
    git -C "$repo" config user.email t@example.com
    git -C "$repo" config user.name t
    git -C "$repo" commit -q --allow-empty -m "chore: root"
    for p in "$@"; do
        mkdir -p "$repo/$(dirname "$p")"
        printf 'x\n' > "$repo/$p"
        git -C "$repo" add "$p"
    done
    printf '%s\n' "$msg" > "$repo/.msg"
    hook_path="$PATH"
    if "$fail_index_read"; then
        real_git=$(command -v git)
        mkdir -p "$repo/tools"
        printf "#!/bin/sh\nif [ \"\$1\" = diff ]; then exit 2; fi\nexec \"%s\" \"\$@\"\n" "$real_git" > "$repo/tools/git"
        chmod +x "$repo/tools/git"
        hook_path="$repo/tools:$hook_path"
    fi
    out="$(cd "$repo" && PATH="$hook_path" "$HOOK" .msg 2>&1)"; rc=$?
    rm -rf "$parent"
}

has() { printf '%s' "$out" | grep -qE "$1" && echo 1 || echo 0; }

# ── the change that caused #450, without the trailer → rejected ───────
run_case core 'feat: a scanned frame reports every code in it' vauchi-core/src/qr/scanner.rs
assert_eq "feat on qr/ without Rig: exit 1" "1" "$rc"
assert_eq "feat on qr/ without Rig: VGT13 in message" "1" "$(has 'VGT13:')"
assert_eq "feat on qr/ without Rig: names the fix" "1" "$(has 'VGT13: .+ — fix: .+')"
assert_eq "feat on qr/ without Rig: cites the page" "1" "$(has 'lint-errors/vgt13-rig-trailer.md')"

# ── both ends of the range → accepted ─────────────────────────────────
run_case core 'fix: read with the cpp-port detector again

Evidence: before: 9 of 40 frames read; after: 30 of 40 frames read
Rig: 7 cm 5/5, 14 cm 5/5 (2026-10-30)' vauchi-core/src/qr_decode.rs
assert_eq "fix with Rig: 7 cm … 14 cm …: exit 0" "0" "$rc"
run_case core 'feat: one multi pass

Rig: 7cm 5/5 in 5-22 s, 14cm 5/5 in 5-14 s' vauchi-core/src/qr_decode.rs
assert_eq "Rig: 7cm … 14cm … without spaces: exit 0" "0" "$rc"

# ── only the near end is what let #450 through → rejected ─────────────
run_case core 'feat: one multi pass

Rig: 7 cm 5/5' vauchi-core/src/qr_decode.rs
assert_eq "Rig: naming 7 cm only: exit 1" "1" "$rc"
run_case core 'feat: one multi pass

Rig: 14 cm 5/5' vauchi-core/src/qr_decode.rs
assert_eq "Rig: naming 14 cm only: exit 1" "1" "$rc"

# ── n/a with a reason → accepted; bare n/a or empty → rejected ────────
run_case core 'refactor: rename the chunk iterator

Spec: unchanged
Rig: n/a — rename only, no change to frame bytes or timing' vauchi-core/src/exchange/multistage/chunker.rs
assert_eq "Rig: n/a — <why>: exit 0" "0" "$rc"
run_case core 'refactor: rename the chunk iterator

Spec: unchanged
Rig: n/a' vauchi-core/src/exchange/multistage/chunker.rs
assert_eq "bare Rig: n/a: exit 1" "1" "$rc"
run_case core 'refactor: rename the chunk iterator

Spec: unchanged
Rig:' vauchi-core/src/exchange/multistage/chunker.rs
assert_eq "empty Rig: exit 1" "1" "$rc"

# ── every multistage file that shapes a frame or its timing ───────────
# (exchange/ is also a VGT12 protocol path, so these carry Spec: and the
# rejection has to be VGT13's.)
for f in qr_codec chunker link_trainer training_header session base45; do
    run_case core 'feat: change it

Spec: unchanged' "vauchi-core/src/exchange/multistage/$f.rs"
    assert_eq "feat on multistage/$f.rs without Rig: exit 1" "1" "$rc"
    assert_eq "feat on multistage/$f.rs without Rig: VGT13" "1" "$(has 'VGT13:')"
done

# ── multistage files that do not shape frames → no trailer ────────────
run_case core 'feat: tighten the commitment

Spec: unchanged' vauchi-core/src/exchange/multistage/commitment.rs
assert_eq "feat on multistage/commitment.rs: exit 0" "0" "$rc"
run_case core 'feat: shake envelope

Spec: unchanged' vauchi-core/src/exchange/multistage/accel_envelope.rs
assert_eq "feat on multistage/accel_envelope.rs: exit 0" "0" "$rc"

# ── the shells' camera readers ────────────────────────────────────────
run_case android 'feat: analyse at 720p' app/src/main/kotlin/app/vauchi/ui/components/QrCodeAnalyzer.kt
assert_eq "android analyzer feat without Rig: exit 1" "1" "$rc"
run_case android 'fix: camera binds once

Evidence: before: two binds in the log; after: one bind in the log' app/src/main/kotlin/app/vauchi/ui/presentation/QrPrimitives.kt
assert_eq "android QR primitives fix without Rig: exit 1" "1" "$rc"
assert_eq "android QR primitives fix without Rig: VGT13" "1" "$(has 'VGT13:')"
run_case ios 'feat: 1280x720 capture' Vauchi/CoreUI/MultipartCameraPreview.swift
assert_eq "ios camera preview feat without Rig: exit 1" "1" "$rc"

# ADR-078 moves these production paths without changing the physical gate.
display_rig_message='feat: adjust the prepared QR view

Spec: unchanged
Rig: 7 cm 1/1, 14 cm 1/1 (fixture text only)'
for qr_relative_path in \
    display/NativeQrEncoder.kt \
    display/NativeQrBitmap.kt \
    ui/presentation/QrPlacement.kt \
    ui/presentation/QrDisplay.kt \
    ui/presentation/QrFrame.kt; do
    for app_name in android android-app; do
        qr_staged_path="display/src/main/kotlin/app/vauchi/$qr_relative_path"
        run_case "$app_name" 'feat: adjust the prepared QR view' "$qr_staged_path"
        assert_eq "$app_name $qr_relative_path without Rig: exit 1" "1" "$rc"
        assert_eq "$app_name $qr_relative_path without Rig: VGT13" "1" "$(has 'VGT13:')"
        run_case "$app_name" "$display_rig_message" "$qr_staged_path"
        assert_eq "$app_name $qr_relative_path both ranges: exit 0" "0" "$rc"
    done
    qr_staged_path="src/main/kotlin/app/vauchi/$qr_relative_path"
    run_case android-display 'feat: adjust the prepared QR view' "$qr_staged_path"
    assert_eq "android-display $qr_relative_path without Rig: exit 1" "1" "$rc"
    assert_eq "android-display $qr_relative_path without Rig: VGT13" "1" "$(has 'VGT13:')"
    run_case android-display "$display_rig_message" "$qr_staged_path"
    assert_eq "android-display $qr_relative_path both ranges: exit 0" "0" "$rc"
done

for camera_file in NativeQrDecoder CameraXCapture CameraPreviewSurface AndroidCameraBackend PreviewCameraPort CameraController; do
    camera_path="src/main/kotlin/app/vauchi/hardware/camera/$camera_file.kt"
    run_case android-hw 'feat: adjust native QR capture' "$camera_path"
    assert_eq "android-hw $camera_file without Rig: exit 1" "1" "$rc"
    assert_eq "android-hw $camera_file without Rig: VGT13" "1" "$(has 'VGT13:')"
    run_case android-hw "$display_rig_message" "$camera_path"
    assert_eq "android-hw $camera_file both ranges: exit 0" "0" "$rc"
done

run_case android-app 'feat: analyse at 720p' app/src/main/kotlin/app/vauchi/ui/components/QrCodeAnalyzer.kt
assert_eq "renamed android app retains camera gate: exit 1" "1" "$rc"
run_case android-display 'feat: adjust QR placement

Rig: 7 cm 1/1' src/main/kotlin/app/vauchi/ui/presentation/QrPlacement.kt
assert_eq "independent display requires far range: exit 1" "1" "$rc"
run_case android-hw 'feat: adjust native QR capture

Rig: 14 cm 1/1' src/main/kotlin/app/vauchi/hardware/camera/NativeQrDecoder.kt
assert_eq "native hardware requires near range: exit 1" "1" "$rc"

fail_index_read=true
run_case android-display "$display_rig_message" src/main/kotlin/app/vauchi/display/NativeQrEncoder.kt
fail_index_read=false
assert_eq "a failed index read cannot approve the display change: exit 1" "1" "$rc"
assert_eq "a failed index read names the unavailable input" "1" "$(has 'cannot read the Git index')"

# ── tests, docs and other paths → no trailer ──────────────────────────
run_case core 'test: real frames at 14 cm' vauchi-core/tests/it/qr_decode_camera_frames_tests.rs
assert_eq "test: commit: exit 0" "0" "$rc"
run_case core 'tidy: wrap a long line' vauchi-core/src/qr_decode.rs
assert_eq "tidy: on qr_decode.rs: exit 0" "0" "$rc"
run_case core 'feat: new settings toggle' vauchi-app/src/settings.rs
assert_eq "feat on vauchi-app/: exit 0" "0" "$rc"
run_case android 'feat: contact list sort' app/src/main/kotlin/app/vauchi/ui/screens/ContactList.kt
assert_eq "android feat elsewhere: exit 0" "0" "$rc"
run_case cli 'feat: print the code' src/qr_decode.rs
assert_eq "cli feat on a same-named path: exit 0" "0" "$rc"
run_case android-display 'feat: render prepared text' src/main/kotlin/app/vauchi/ui/presentation/PresentationTextNode.kt
assert_eq "independent display non-QR change: exit 0" "0" "$rc"
run_case android-hw 'feat: collect a location' src/main/kotlin/app/vauchi/hardware/location/AndroidLocationProvider.kt
assert_eq "native hardware non-QR change: exit 0" "0" "$rc"
run_case android-display 'test: render QR pixels' src/test/kotlin/app/vauchi/display/NativeQrBitmapTest.kt
assert_eq "independent display test-only change: exit 0" "0" "$rc"

printf '\n%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
