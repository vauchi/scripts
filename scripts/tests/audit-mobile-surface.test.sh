#!/usr/bin/env bash
# SPDX-FileCopyrightText: 2026 Mattia Egloff <mattia.egloff@pm.me>
#
# SPDX-License-Identifier: GPL-3.0-or-later

# Regression suite for audit-mobile-surface.sh — the ratchet floor of
# the pure-functional-core program (Phase 0 / Task 0.1).
#
# Each test builds a tiny synthetic workspace under a tempdir whose
# layout mirrors the real one (core/vauchi-platform, core/vauchi-core,
# ios/Vauchi, …), runs the script against it, and asserts the JSON
# counters.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT="$SCRIPT_DIR/../audit-mobile-surface.sh"

pass=0
fail=0

assert_eq() {
    local name="$1" want="$2" got="$3"
    if [[ "$want" == "$got" ]]; then
        printf '  PASS %s\n' "$name"
        pass=$((pass + 1))
    else
        printf '  FAIL %s\n    want: %q\n    got:  %q\n' "$name" "$want" "$got" >&2
        fail=$((fail + 1))
    fi
}

# extract_counter <json> <key>  — grab `"key": N` value from the JSON.
extract_counter() {
    printf '%s' "$1" | awk -v k="\"$2\"" '
        $1 ~ k {
            v = $0
            sub(/.*:[[:space:]]+/, "", v)
            sub(/,$/, "", v)
            print v
            exit
        }
    '
}

# ── 1. Empty workspace ────────────────────────────────────────────────
# A workspace where none of the probed subdirs exist must yield all
# zero counters and still produce valid JSON (no error, exit 0).
test_empty_workspace() {
    local root; root=$(mktemp -d)
    out=$("$SCRIPT" "$root")
    rc=$?
    assert_eq "empty: exit 0" 0 "$rc"
    for key in mobile_uniffi_exports mobile_pub_fns lib_rs_mobile_returns \
               platform_app_engine_pub_fns_total platform_app_engine_non_humble \
               ios_vauchi_platform_imports ios_mobile_type_refs \
               android_mobile_refs macos_mobile_refs capability_reporting_wired \
               tui_screen_variants \
               core_system_time_now core_thread_rng core_thread_sleep \
               core_ambient_now_secs; do
        assert_eq "empty: $key == 0" "0" "$(extract_counter "$out" "$key")"
    done
    rm -rf "$root"
}

# ── 2. mobile_*.rs counters ───────────────────────────────────────────
# Two synthetic mobile_*.rs files: three #[uniffi::export] lines and
# four indented `pub fn` lines total.
test_mobile_counters() {
    local root; root=$(mktemp -d)
    local src="$root/core/vauchi-platform/src"
    mkdir -p "$src"
    cat >"$src/mobile_alpha.rs" <<'RS'
#[uniffi::export]
impl VauchiPlatform {
    pub fn alpha_one(&self) -> i32 { 1 }
    pub fn alpha_two(&self) -> i32 { 2 }
}

#[uniffi::export]
impl VauchiPlatform {
    pub fn alpha_three(&self) -> i32 { 3 }
}
RS
    cat >"$src/mobile_beta.rs" <<'RS'
#[uniffi::export]
impl VauchiPlatform {
    pub fn beta_one(&self) -> i32 { 4 }
}
RS
    # Distractor file that should NOT be counted (not mobile_*.rs).
    cat >"$src/lib.rs" <<'RS'
pub fn unrelated() {}
RS
    out=$("$SCRIPT" "$root")
    assert_eq "mobile: uniffi_exports == 3" \
        "3" "$(extract_counter "$out" mobile_uniffi_exports)"
    assert_eq "mobile: pub_fns == 4" \
        "4" "$(extract_counter "$out" mobile_pub_fns)"
    rm -rf "$root"
}

# ── 3. lib.rs Mobile* signature lines ─────────────────────────────────
# Two lines mention MobileError or `-> Mobile…`; one decoy that does
# not.
test_lib_rs_mobile_returns() {
    local root; root=$(mktemp -d)
    local src="$root/core/vauchi-platform/src"
    mkdir -p "$src"
    cat >"$src/lib.rs" <<'RS'
pub fn legacy_one() -> Result<(), MobileError> { Ok(()) }
pub fn legacy_two() -> MobileFoo { todo!() }
pub fn modern() -> Result<(), AppError> { Ok(()) }
RS
    out=$("$SCRIPT" "$root")
    assert_eq "lib_rs_mobile_returns == 2" \
        "2" "$(extract_counter "$out" lib_rs_mobile_returns)"
    rm -rf "$root"
}

# ── 4. PlatformAppEngine non-Humble counter ───────────────────────────
# Two pub fns inside an `impl PlatformAppEngine` block: one allow-list
# member (`boot`), one legacy (`create_recovery_claim`). Plus a decoy
# pub fn in an UNRELATED impl that must not be counted.
test_pae_non_humble() {
    local root; root=$(mktemp -d)
    local src="$root/core/vauchi-platform/src"
    mkdir -p "$src"
    cat >"$src/platform_app_engine.rs" <<'RS'
impl PlatformAppEngine {
    pub fn boot(&self) -> () { () }
    pub fn create_recovery_claim(&self) -> () { () }
}

impl SomethingElse {
    pub fn distractor(&self) -> () { () }
}
RS
    out=$("$SCRIPT" "$root")
    assert_eq "pae: pub_fns_total == 2" \
        "2" "$(extract_counter "$out" platform_app_engine_pub_fns_total)"
    assert_eq "pae: non_humble == 1" \
        "1" "$(extract_counter "$out" platform_app_engine_non_humble)"
    rm -rf "$root"
}

# ── 5. iOS counters ───────────────────────────────────────────────────
test_ios_counters() {
    local root; root=$(mktemp -d)
    local ios="$root/ios/Vauchi"
    mkdir -p "$ios/Views" "$ios/Generated" "$ios/Libs/VauchiPlatformLocal/Sources/VauchiPlatform"
    cat >"$ios/Views/Foo.swift" <<'SW'
import SwiftUI
import VauchiPlatform

struct FooView: View {
    let item: MobileContact
    let extra: MobileIdentity
}
SW
    cat >"$ios/Views/Bar.swift" <<'SW'
import VauchiPlatform
let x = MobileCard()
SW
    # Generated/ — binding mirror, must NOT contribute to the counter.
    cat >"$ios/Generated/vauchi_mobile.swift" <<'SW'
public class MobileContact { }
public class MobileIdentity { }
public class MobileCard { }
public class MobileError { }
public class MobileNoise1 { }
public class MobileNoise2 { }
SW
    # Libs/ — local SPM checkout of vauchi-platform-swift, also binding
    # mirror, also must NOT contribute. Adds many more Mobile* lines so
    # any regression that re-includes Libs/ is loud.
    cat >"$ios/Libs/VauchiPlatformLocal/Sources/VauchiPlatform/vauchi_platform.swift" <<'SW'
public class MobileLib1 { }
public class MobileLib2 { }
public class MobileLib3 { }
public class MobileLib4 { }
public class MobileLib5 { }
SW
    out=$("$SCRIPT" "$root")
    assert_eq "ios: vauchi_platform_imports == 2" \
        "2" "$(extract_counter "$out" ios_vauchi_platform_imports)"
    # Foo.swift has 2 Mobile* references (MobileContact, MobileIdentity),
    # Bar.swift has 1 (MobileCard) → 3 total. Generated/ (6 lines) and
    # Libs/ (5 lines) are excluded.
    assert_eq "ios: mobile_type_refs == 3 (Generated/ + Libs/ excluded)" \
        "3" "$(extract_counter "$out" ios_mobile_type_refs)"
    rm -rf "$root"
}

# ── 5b. macOS counter ─────────────────────────────────────────────────
test_macos_counter() {
    local root; root=$(mktemp -d)
    local mac="$root/macos/Vauchi"
    mkdir -p "$mac/Services" "$mac/Generated" "$mac/Libs/VauchiPlatformLocal/Sources/VauchiPlatform"
    cat >"$mac/Services/Foo.swift" <<'SW'
import VauchiPlatform
let a: MobileContact = TODO()
let b: MobileError = TODO()
SW
    # Generated/ + Libs/ noise — must NOT contribute.
    cat >"$mac/Generated/vauchi_platform.swift" <<'SW'
public class MobileMirror1 { }
public class MobileMirror2 { }
public class MobileMirror3 { }
SW
    cat >"$mac/Libs/VauchiPlatformLocal/Sources/VauchiPlatform/vauchi_platform.swift" <<'SW'
public class MobileSpm1 { }
public class MobileSpm2 { }
SW
    out=$("$SCRIPT" "$root")
    assert_eq "macos: mobile_refs == 2 (Generated/ + Libs/ excluded)" \
        "2" "$(extract_counter "$out" macos_mobile_refs)"
    rm -rf "$root"
}

# ── 6. Android counter ────────────────────────────────────────────────
test_android_counter() {
    local root; root=$(mktemp -d)
    local ui="$root/android/app/src/main/kotlin/app/vauchi/ui"
    mkdir -p "$ui/screens"
    cat >"$ui/screens/Foo.kt" <<'KT'
import app.vauchi.binding.MobileContact
import app.vauchi.binding.MobileIdentity
val x: MobileContact = TODO()
KT
    out=$("$SCRIPT" "$root")
    assert_eq "android: mobile_refs == 3" \
        "3" "$(extract_counter "$out" android_mobile_refs)"
    rm -rf "$root"
}

# ── 7. TUI Screen variants ────────────────────────────────────────────
test_tui_screen_variants() {
    local root; root=$(mktemp -d)
    local s="$root/tui/src/app"
    mkdir -p "$s"
    cat >"$s/state.rs" <<'RS'
pub enum Screen {
    Home,
    Contacts,
    Settings,
    /// some doc
    About,
}

pub enum NotAScreen {
    Foo,
    Bar,
}
RS
    out=$("$SCRIPT" "$root")
    assert_eq "tui: screen_variants == 4" \
        "4" "$(extract_counter "$out" tui_screen_variants)"
    rm -rf "$root"
}

# ── 8. core nondeterminism callsites ──────────────────────────────────
test_core_nondeterminism() {
    local root; root=$(mktemp -d)
    local src="$root/core/vauchi-core/src"
    mkdir -p "$src/sub"
    cat >"$src/foo.rs" <<'RS'
fn a() { let _ = SystemTime::now(); }
fn b() { let _ = SystemTime::now(); }
fn c() { let _ = thread_rng().gen::<u32>(); }
fn e() { let _ = crate::clock::ambient_now_secs(); }
RS
    cat >"$src/sub/bar.rs" <<'RS'
fn d() { thread::sleep(std::time::Duration::from_millis(10)); }
fn f() { let _ = crate::clock::ambient_now_secs(); }
fn g() { let _ = crate::clock::ambient_now_secs(); }
RS
    # sleeper.rs is the seam's own definition file — its
    # `SystemSleeper` impl + doc comments mention `thread::sleep`
    # but must NOT contribute to the counter. Adds 3 such lines so
    # any regression that re-includes the seam file is loud.
    cat >"$src/sleeper.rs" <<'RS'
//! Today vauchi-core calls std::thread::sleep from several sites.
impl Sleeper for SystemSleeper {
    fn sleep(&self, d: Duration) { std::thread::sleep(d); }
}
RS
    # Same precedent for clock.rs: the `Clock` seam's own definition
    # file holds the one production `SystemTime::now()` call (the
    # `SystemClock::now` impl) plus doc-comment references. Counting
    # those would peg `core_system_time_now` at "fixture lines + 1"
    # forever. Adds 2 such lines so a regression dropping the
    # `clock.rs` exclusion would push the counter from 2 to 4
    # (still 2 expected here).
    cat >"$src/clock.rs" <<'RS'
//! `SystemTime::now()` will, over Phase 1, route through this seam.
impl Clock for SystemClock {
    fn now(&self) -> SystemTime { SystemTime::now() }
}
RS
    # `core_thread_sleep` walks all four core crates (vauchi-core,
    # vauchi-app, vauchi-cabi, vauchi-platform) — the slice-31
    # cascade landed sleeper-threading work in each of them, so
    # the counter has to span the same surface as the plan's
    # completion criteria. Add one hit per crate-outside-vauchi-core
    # plus two in vauchi-platform so a regression that drops any
    # one root from the loop changes the expected count by a
    # known delta. Total: 1 (vauchi-core) + 1 (app) + 1 (cabi)
    # + 2 (platform) = 5.
    local app_src="$root/core/vauchi-app/src"
    local cabi_src="$root/core/vauchi-cabi/src"
    local platform_src="$root/core/vauchi-platform/src"
    mkdir -p "$app_src" "$cabi_src" "$platform_src"
    cat >"$app_src/connection.rs" <<'RS'
fn reconnect() { thread::sleep(std::time::Duration::from_millis(50)); }
RS
    cat >"$cabi_src/device_link.rs" <<'RS'
fn poll() { thread::sleep(std::time::Duration::from_secs(1)); }
RS
    cat >"$platform_src/poll.rs" <<'RS'
fn cycle() { thread::sleep(std::time::Duration::from_millis(200)); }
fn responsive() { thread::sleep(std::time::Duration::from_millis(25)); }
RS
    out=$("$SCRIPT" "$root")
    assert_eq "core: system_time_now == 2 (clock.rs excluded)" \
        "2" "$(extract_counter "$out" core_system_time_now)"
    assert_eq "core: thread_rng == 1" \
        "1" "$(extract_counter "$out" core_thread_rng)"
    assert_eq "core: thread_sleep == 5 (sleeper.rs excluded; spans 4 core crates)" \
        "5" "$(extract_counter "$out" core_thread_sleep)"
    assert_eq "core: ambient_now_secs == 3" \
        "3" "$(extract_counter "$out" core_ambient_now_secs)"
    rm -rf "$root"
}

# ── 9. JSON output is valid ───────────────────────────────────────────
test_json_validity() {
    local root; root=$(mktemp -d)
    out=$("$SCRIPT" "$root")
    if printf '%s' "$out" | python3 -m json.tool >/dev/null 2>&1; then
        printf '  PASS json: parses as JSON\n'
        pass=$((pass + 1))
    else
        printf '  FAIL json: invalid JSON\n    output: %s\n' "$out" >&2
        fail=$((fail + 1))
    fi
    rm -rf "$root"
}

# ── 10. Missing workspace root → exit 2 ───────────────────────────────
test_bad_workspace() {
    set +e
    "$SCRIPT" "/does/not/exist/$RANDOM" >/dev/null 2>&1
    rc=$?
    set -e
    assert_eq "bad workspace: exit 2" "2" "$rc"
}

# ── 5d. capability_reporting_wired (G5 regression guard) ──────────────
# One UniFFI frontend per call site. Each frontend that invokes
# `setDeviceCapabilitiesJson` in hand-written source contributes 1;
# binding mirrors (Generated/, Libs/) and Gradle output (build/) must
# NOT contribute. Target 3. Also asserts the floor DROPS when a
# frontend's call is removed (the regression this guard exists to
# catch).
test_capability_reporting_wired() {
    local root; root=$(mktemp -d)
    local ios="$root/ios/Vauchi/Services"
    local mac="$root/macos/Vauchi/Services"
    local andr="$root/android/app/src/main/kotlin/app/vauchi/util"
    mkdir -p "$ios" "$mac" "$andr"
    cat >"$ios/DeviceCapabilitiesPusher.swift" <<'SW'
func pushDeviceCapabilities(engine: PlatformAppEngine?) {
    try engine?.setDeviceCapabilitiesJson(capabilitiesJson: json)
}
SW
    cat >"$mac/DeviceCapabilitiesPusher.swift" <<'SW'
func pushDeviceCapabilities(engine: PlatformAppEngine?) {
    try engine?.setDeviceCapabilitiesJson(capabilitiesJson: json)
}
SW
    cat >"$andr/DeviceCapabilitiesPusher.kt" <<'KT'
internal fun pushDeviceCapabilities(context: Context, engine: PlatformAppEngine?) {
    engine.setDeviceCapabilitiesJson(json)
}
KT
    # Mirrors / build output — declare the symbol but must NOT count.
    mkdir -p "$root/ios/Vauchi/Generated" \
             "$root/macos/Vauchi/Libs/VauchiPlatformLocal" \
             "$root/android/app/src/main/kotlin/app/vauchi/build"
    cat >"$root/ios/Vauchi/Generated/vauchi_platform.swift" <<'SW'
open func setDeviceCapabilitiesJson(capabilitiesJson: String) throws { }
SW
    cat >"$root/macos/Vauchi/Libs/VauchiPlatformLocal/vauchi_platform.swift" <<'SW'
open func setDeviceCapabilitiesJson(capabilitiesJson: String) throws { }
SW
    cat >"$root/android/app/src/main/kotlin/app/vauchi/build/Generated.kt" <<'KT'
fun setDeviceCapabilitiesJson(json: String) { }
KT
    out=$("$SCRIPT" "$root")
    assert_eq "capability: all three frontends wired == 3 (mirrors excluded)" \
        "3" "$(extract_counter "$out" capability_reporting_wired)"

    # Regression: drop the Android call → floor must fall to 2.
    rm -f "$andr/DeviceCapabilitiesPusher.kt"
    out=$("$SCRIPT" "$root")
    assert_eq "capability: floor drops to 2 when Android unwired" \
        "2" "$(extract_counter "$out" capability_reporting_wired)"
    rm -rf "$root"
}

# ── run ──────────────────────────────────────────────────────────────
test_empty_workspace
test_mobile_counters
test_lib_rs_mobile_returns
test_pae_non_humble
test_ios_counters
test_macos_counter
test_android_counter
test_capability_reporting_wired
test_tui_screen_variants
test_core_nondeterminism
test_json_validity
test_bad_workspace

printf '\n%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
