#!/usr/bin/env bash
# SPDX-FileCopyrightText: 2026 Mattia Egloff <mattia.egloff@pm.me>
#
# SPDX-License-Identifier: GPL-3.0-or-later

# Sentinel regression suite for audit-frontend-i18n-strings.sh — the
# hardcoded-English ratchet over frontends that do not yet have a dedicated
# i18n string lint.
#
# Per CC-20 / CC-21 these tests are NON-tautological: each builds a tiny
# synthetic frontend tree, plants known sentinel lines, runs the real script,
# and asserts the gate COUNTS user-visible English literals and does NOT count
# documented false-positive shapes (single letters, locale keys, all-uppercase
# constants, digits/punctuation-only strings). It also asserts the --check
# ratchet exits nonzero when a planted literal pushes the count above a tiny
# baseline and exits zero when at/below baseline.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
SCRIPT="$SCRIPT_DIR/../audit-frontend-i18n-strings.sh"

pass=0
fail=0

assert_eq() {
    name="$1"; want="$2"; got="$3"
    if [ "$want" = "$got" ]; then
        printf '  PASS %s\n' "$name"
        pass=$((pass + 1))
    else
        printf '  FAIL %s\n    want: %s\n    got:  %s\n' "$name" "$want" "$got" >&2
        fail=$((fail + 1))
    fi
}

# extract_counter <json> <key> — grab `"key": N` value from the JSON.
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

# ── 1. Empty workspace → all zero, valid JSON, exit 0 ───────────────────────
test_empty_workspace() {
    root=$(mktemp -d)
    out=$("$SCRIPT" "$root"); rc=$?
    assert_eq "empty: exit 0" 0 "$rc"
    assert_eq "empty: android == 0"  "0" "$(extract_counter "$out" android)"
    assert_eq "empty: windows == 0"  "0" "$(extract_counter "$out" windows)"
    assert_eq "empty: linux_qt == 0" "0" "$(extract_counter "$out" linux_qt)"
    assert_eq "empty: linux_gtk == 0" "0" "$(extract_counter "$out" linux_gtk)"
    assert_eq "empty: tui == 0"      "0" "$(extract_counter "$out" tui)"
    assert_eq "empty: cli == 0"      "0" "$(extract_counter "$out" cli)"
    assert_eq "empty: total == 0"    "0" "$(extract_counter "$out" total)"
    rm -rf "$root"
}

# ── 2. Android sentinel — counts Text("...") literals, skips stringResource ─
test_android_sentinel() {
    root=$(mktemp -d)
    dir="$root/android/app/src/main/kotlin/app/vauchi"
    mkdir -p "$dir"
    cat >"$dir/MainActivity.kt" <<'KT'
@Composable
fun Screen() {
    Text("Hello world")
    Text(text = "Welcome back")
    Text(stringResource(R.string.title))
    Text("")                      // empty: not English
    Text("A")                     // single letter: too short
    Text("OK")                    // all uppercase: no lowercase
    Text("snackbar.title")        // locale key: contains '.'
}
KT
    test_dir="$root/android/app/src/androidTest/kotlin/app/vauchi"
    mkdir -p "$test_dir"
    cat >"$test_dir/ProbeTest.kt" <<'KT'
fun probe() {
    Text("Instrumentation probe copy")
}
KT
    out=$("$SCRIPT" "$root")
    assert_eq "android: counts 2 English Text literals" \
        "2" "$(extract_counter "$out" android)"
    rm -rf "$root"
}

# ── 3. Windows sentinel — counts XAML user-facing attributes ────────────────
test_windows_sentinel() {
    root=$(mktemp -d)
    dir="$root/windows/Vauchi/Views"
    mkdir -p "$dir"
    cat >"$dir/MainPage.xaml" <<'XAML'
<Page>
    <TextBlock Content="Hello world" />
    <TextBox Text="Enter name" PlaceholderText="Type here" />
    <Button Header="Save changes"
            ToolTipService.ToolTip="Persist edits" />
    <TextBlock x:Uid="Greeting" />  <!-- localized: no literal -->
</Page>
XAML
    out=$("$SCRIPT" "$root")
    assert_eq "windows: counts 5 English XAML literals" \
        "5" "$(extract_counter "$out" windows)"
    rm -rf "$root"
}

# ── 3b. Windows false-positive guard — only the matched attribute counts ─────
test_windows_false_positive_guard() {
    root=$(mktemp -d)
    dir="$root/windows/Vauchi/Views"
    mkdir -p "$dir"
    cat >"$dir/MainPage.xaml" <<'XAML'
<Page>
    <!-- Only "Hello" counts; "Center", "Wrap", and x:Name values on the same
         line must NOT be picked up by the attribute-value extractor. -->
    <TextBlock Text="Hello" VerticalAlignment="Center" TextWrapping="Wrap"
               x:Name="GreetingLabel" />
</Page>
XAML
    out=$("$SCRIPT" "$root")
    assert_eq "windows: ignores sibling attribute values on matched line" \
        "1" "$(extract_counter "$out" windows)"
    rm -rf "$root"
}

# ── 4. linux-qt sentinel — counts QStringLiteral and setter calls ───────────
test_linux_qt_sentinel() {
    root=$(mktemp -d)
    dir="$root/linux-qt/src"
    mkdir -p "$dir"
    cat >"$dir/window.cpp" <<'CPP'
void setup() {
    auto label = new QLabel(QStringLiteral("Hello world"));
    button->setText("Click me");
    window->setWindowTitle("Vauchi Wallet");
    input->setPlaceholderText("Type seed words");
    widget->setObjectName(QStringLiteral("image-edit-affordance"));
    // Not counted:
    const char* key = "settings.general";   // locale key
    QLabel* l = new QLabel(tr("already_localized"));  // not in grep pattern
}
CPP
    out=$("$SCRIPT" "$root")
    assert_eq "linux_qt: counts 4 English literals" \
        "4" "$(extract_counter "$out" linux_qt)"
    rm -rf "$root"
}

# ── 4b. linux-qt protocol keys and shortcuts are not English ────────────────
# The Qt shell decodes Core's commands by their protocol names
# (QStringLiteral("ReplaceSurface"), ("Text")) and binds key sequences
# (QStringLiteral("Ctrl+K")); 86 of those read as hardcoded English and kept
# the nightly ratchet red (vauchi/private#543). A one-word label handed to a
# setter is still copy and still counts.
test_linux_qt_protocol_keys_guard() {
    root=$(mktemp -d)
    dir="$root/linux-qt/src"
    mkdir -p "$dir"
    cat >"$dir/decode.cpp" <<'CPP'
void decode(const QJsonObject& command) {
    if (command.contains(QStringLiteral("ReplaceSurface"))) {}
    if (command.contains(QStringLiteral("SetContextBar"))) {}
    auto node = command.value(QStringLiteral("Text"));
    button->setShortcut(QKeySequence(QStringLiteral("Ctrl+K")));
    button->setShortcut(QKeySequence(QStringLiteral("Alt+Down")));
    // Counted: copy, even when it is one word.
    auto label = new QLabel(QStringLiteral("Sync failed"));
    cancel->setText("Cancel");
}
CPP
    out=$("$SCRIPT" "$root")
    assert_eq "linux_qt: protocol keys and shortcuts not counted, copy is" \
        "2" "$(extract_counter "$out" linux_qt)"
    rm -rf "$root"
}

# ── 5. linux-gtk sentinel — counts .label/.title/.placeholder_text ──────────
test_linux_gtk_sentinel() {
    root=$(mktemp -d)
    dir="$root/linux-gtk/src"
    mkdir -p "$dir"
    cat >"$dir/widgets.rs" <<'RS'
fn build() -> adw::ApplicationWindow {
    let row = adw::ActionRow::new()
        .title("Settings")
        .subtitle("not matched")
        .build();
    let entry = gtk::Entry::builder()
        .placeholder_text("Search contacts")
        .build();
    let button = gtk::Button::builder()
        .label("Hello world")
        .build();
}
RS
    out=$("$SCRIPT" "$root")
    assert_eq "linux_gtk: counts 3 English literals" \
        "3" "$(extract_counter "$out" linux_gtk)"
    rm -rf "$root"
}

# ── 6. TUI sentinel — counts Paragraph/Line/Span literal builders ───────────
test_tui_sentinel() {
    root=$(mktemp -d)
    dir="$root/tui/src"
    mkdir -p "$dir"
    cat >"$dir/render.rs" <<'RS'
fn render() {
    let p = Paragraph::new("Hello world");
    let line = Line::from("Welcome back");
    let span = Span::raw("OK");            // all uppercase: no lowercase
    let other = Span::raw("x");            // single letter
}
RS
    out=$("$SCRIPT" "$root")
    assert_eq "tui: counts 2 English literals" \
        "2" "$(extract_counter "$out" tui)"
    rm -rf "$root"
}

# ── 7. CLI sentinel — counts clap attrs and println!/eprintln! ──────────────
test_cli_sentinel() {
    root=$(mktemp -d)
    dir="$root/cli/src"
    mkdir -p "$dir"
    cat >"$dir/main.rs" <<'RS'
#[derive(Parser)]
#[command(name = "vauchi")]
#[command(about = "A secure payment wallet")]
struct Cli {
    #[arg(help = "Path to configuration file")]
    path: String,
    #[arg(long, long_about = "Override default network endpoint")]
    endpoint: String,
}

fn warn() {
    println!("Transaction pending");
    eprintln!("Connection failed");
    println!("x");              // single letter
    eprintln!("OK");            // all uppercase
}
RS
    out=$("$SCRIPT" "$root")
    assert_eq "cli: counts 5 English literals" \
        "5" "$(extract_counter "$out" cli)"
    rm -rf "$root"
}

# ── 8. English filter edge cases ────────────────────────────────────────────
test_english_filter() {
    root=$(mktemp -d)
    dir="$root/tui/src"
    mkdir -p "$dir"
    cat >"$dir/filter.rs" <<'RS'
fn show() {
    Paragraph::new("Hello");      // starts letter, has lowercase, length OK
    Paragraph::new("hello");      // starts lowercase letter
    Paragraph::new("A");          // too short
    Paragraph::new("AB");         // no lowercase
    Paragraph::new("123");        // no letter
    Paragraph::new("Hello.");     // contains dot (locale key style)
    Paragraph::new("ui.error");   // locale key
    Paragraph::new("");           // empty
    Paragraph::new("...");        // only punctuation
}
RS
    out=$("$SCRIPT" "$root")
    assert_eq "filter: only 2 real English strings" \
        "2" "$(extract_counter "$out" tui)"
    rm -rf "$root"
}

# ── 9. Total = sum of all frontends ─────────────────────────────────────────
test_total_sums() {
    root=$(mktemp -d)
    mkdir -p "$root/android/app/src/main/kotlin/app/vauchi"
    mkdir -p "$root/windows/Vauchi/Views"
    cat >"$root/android/app/src/main/kotlin/app/vauchi/Main.kt" <<'KT'
@Composable fun Screen() { Text("Hello") }
KT
    cat >"$root/windows/Vauchi/Views/P.xaml" <<'XAML'
<Page><TextBlock Text="World" /></Page>
XAML
    out=$("$SCRIPT" "$root")
    assert_eq "total: 1 android + 1 windows == 2" \
        "2" "$(extract_counter "$out" total)"
    rm -rf "$root"
}

# ── 10. --check ratchet: exits nonzero ABOVE baseline ───────────────────────
test_check_above_baseline_fails() {
    root=$(mktemp -d)
    dir="$root/cli/src"
    mkdir -p "$dir"
    cat >"$dir/main.rs" <<'RS'
fn run() {
    println!("One");
    println!("Two");
}
RS
    base="$root/baseline.json"
    cat >"$base" <<'JSON'
{
  "schema_version": 1,
  "totals": {
    "android": 0,
    "windows": 0,
    "linux_qt": 0,
    "linux_gtk": 0,
    "tui": 0,
    "cli": 1,
    "total": 1
  }
}
JSON
    set +e
    "$SCRIPT" --check "$base" "$root" >/dev/null 2>&1
    rc=$?
    set -e
    assert_eq "check: exit 1 when count exceeds baseline" "1" "$rc"
    rm -rf "$root"
}

# ── 11. --check ratchet: exits zero AT/BELOW baseline ───────────────────────
test_check_at_or_below_baseline_passes() {
    root=$(mktemp -d)
    dir="$root/cli/src"
    mkdir -p "$dir"
    cat >"$dir/main.rs" <<'RS'
fn run() {
    println!("One");
    println!("Two");
}
RS
    base_at="$root/baseline_at.json"
    cat >"$base_at" <<'JSON'
{
  "totals": {
    "android": 0,
    "windows": 0,
    "linux_qt": 0,
    "linux_gtk": 0,
    "tui": 0,
    "cli": 2,
    "total": 2
  }
}
JSON
    base_below="$root/baseline_below.json"
    cat >"$base_below" <<'JSON'
{
  "totals": {
    "android": 0,
    "windows": 0,
    "linux_qt": 0,
    "linux_gtk": 0,
    "tui": 0,
    "cli": 5,
    "total": 5
  }
}
JSON
    set +e
    "$SCRIPT" --check "$base_at" "$root" >/dev/null 2>&1; rc_at=$?
    "$SCRIPT" --check "$base_below" "$root" >/dev/null 2>&1; rc_below=$?
    set -e
    assert_eq "check: exit 0 at baseline" "0" "$rc_at"
    assert_eq "check: exit 0 below baseline" "0" "$rc_below"
    rm -rf "$root"
}

# ── 12. --check missing baseline file → exit 2 ──────────────────────────────
test_check_missing_baseline() {
    root=$(mktemp -d)
    set +e
    "$SCRIPT" --check "/does/not/exist/$$.json" "$root" >/dev/null 2>&1
    rc=$?
    set -e
    assert_eq "check: missing baseline → exit 2" "2" "$rc"
    rm -rf "$root"
}

# ── 13. JSON output parses ──────────────────────────────────────────────────
test_json_validity() {
    root=$(mktemp -d)
    out=$("$SCRIPT" "$root")
    if printf '%s' "$out" | python3 -m json.tool >/dev/null 2>&1; then
        printf '  PASS json: parses as JSON\n'; pass=$((pass + 1))
    else
        printf '  FAIL json: invalid JSON\n    output: %s\n' "$out" >&2
        fail=$((fail + 1))
    fi
    rm -rf "$root"
}

# ── 14. Bad workspace root → exit 2 ─────────────────────────────────────────
test_bad_workspace() {
    set +e
    "$SCRIPT" "/does/not/exist/$$" >/dev/null 2>&1
    rc=$?
    set -e
    assert_eq "bad workspace: exit 2" "2" "$rc"
}

# ── run ─────────────────────────────────────────────────────────────────────
test_empty_workspace
test_android_sentinel
test_windows_sentinel
test_windows_false_positive_guard
test_linux_qt_sentinel
test_linux_qt_protocol_keys_guard
test_linux_gtk_sentinel
test_tui_sentinel
test_cli_sentinel
test_english_filter
test_total_sums
test_check_above_baseline_fails
test_check_at_or_below_baseline_passes
test_check_missing_baseline
test_json_validity
test_bad_workspace

printf '\n%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
