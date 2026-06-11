#!/bin/bash
# SPDX-FileCopyrightText: 2026 Mattia Egloff <mattia.egloff@pm.me>
#
# SPDX-License-Identifier: GPL-3.0-or-later

# Generate a cross-platform VRT (Visual Regression Testing) gallery.
#
# Collects baseline screenshots/snapshots from all platforms and produces
# a self-contained HTML page showing every baseline side-by-side.
#
# Platforms:
#   - iOS:       swift-snapshot-testing PNG snapshots
#   - macOS:     swift-snapshot-testing PNG snapshots
#   - Android:   Compose Preview Screenshot Testing PNG snapshots
#   - Web Demo:  Playwright snapshots
#   - Linux GTK: AT-SPI screenshot baselines
#   - Linux Qt:  AT-SPI screenshot baselines
#   - TUI:       insta text snapshots (rendered as <pre> blocks)
#
# Usage:
#   ./scripts/vrt-gallery.sh            # Generate and open gallery
#   ./scripts/vrt-gallery.sh --no-open  # Generate without opening

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
OUTPUT_DIR="$PROJECT_ROOT/tmp/vrt-gallery"
OUTPUT_FILE="$OUTPUT_DIR/index.html"

# Platform baseline directories
IOS_SNAPS="$PROJECT_ROOT/ios/VauchiSnapshotTests/__Snapshots__/VisualRegressionTests"
MACOS_SNAPS="$PROJECT_ROOT/macos/VauchiSnapshotTests/__Snapshots__/ScreenSnapshotTests"
ANDROID_SNAPS="$PROJECT_ROOT/android/app/src/screenshotTestDebug/reference/app/vauchi/CoreUIComponentScreenshotTestsKt"
WEB_DEMO_SNAPS="$PROJECT_ROOT/web-demo/tests/playwright/vrt.spec.ts-snapshots"
LINUX_GTK_SNAPS="$PROJECT_ROOT/linux-gtk/tests/atspi/snapshots/baseline"
LINUX_QT_SNAPS="$PROJECT_ROOT/linux-qt/tests/atspi/snapshots/baseline"
TUI_SNAPS="$PROJECT_ROOT/tui/tests/it/snapshots"

NO_OPEN=false
if [[ "${1:-}" == "--no-open" ]]; then
    NO_OPEN=true
fi

# ── Prepare output ────────────────────────────────────────────────
mkdir -p "$OUTPUT_DIR/images/ios" "$OUTPUT_DIR/images/macos" "$OUTPUT_DIR/images/android" "$OUTPUT_DIR/images/web-demo" "$OUTPUT_DIR/images/linux-gtk" "$OUTPUT_DIR/images/linux-qt"

# ── Collect iOS baselines ─────────────────────────────────────────
ios_count=0
if [ -d "$IOS_SNAPS" ]; then
    for f in "$IOS_SNAPS"/*.png; do
        [ -f "$f" ] || continue
        cp "$f" "$OUTPUT_DIR/images/ios/"
        ios_count=$((ios_count + 1))
    done
fi

# ── Collect macOS baselines ──────────────────────────────────────
macos_count=0
if [ -d "$MACOS_SNAPS" ]; then
    for f in "$MACOS_SNAPS"/*.png; do
        [ -f "$f" ] || continue
        cp "$f" "$OUTPUT_DIR/images/macos/"
        macos_count=$((macos_count + 1))
    done
fi

# ── Collect Android baselines ─────────────────────────────────────
android_count=0
if [ -d "$ANDROID_SNAPS" ]; then
    for f in "$ANDROID_SNAPS"/*.png; do
        [ -f "$f" ] || continue
        cp "$f" "$OUTPUT_DIR/images/android/"
        android_count=$((android_count + 1))
    done
fi

# ── Collect web-demo baselines ───────────────────────────────────
web_demo_count=0
if [ -d "$WEB_DEMO_SNAPS" ]; then
    for f in "$WEB_DEMO_SNAPS"/*.png; do
        [ -f "$f" ] || continue
        cp "$f" "$OUTPUT_DIR/images/web-demo/"
        web_demo_count=$((web_demo_count + 1))
    done
fi

# ── Collect Linux GTK baselines ───────────────────────────────────
linux_gtk_count=0
if [ -d "$LINUX_GTK_SNAPS" ]; then
    for f in "$LINUX_GTK_SNAPS"/*.png; do
        [ -f "$f" ] || continue
        cp "$f" "$OUTPUT_DIR/images/linux-gtk/"
        linux_gtk_count=$((linux_gtk_count + 1))
    done
fi

# ── Collect Linux Qt baselines ───────────────────────────────────
# linux-qt nests baselines per theme (baseline/dark/, baseline/light/);
# flatten with a theme prefix so both variants land in the gallery.
linux_qt_count=0
if [ -d "$LINUX_QT_SNAPS" ]; then
    for f in "$LINUX_QT_SNAPS"/*.png "$LINUX_QT_SNAPS"/*/*.png; do
        [ -f "$f" ] || continue
        theme_dir=$(basename "$(dirname "$f")")
        if [ "$theme_dir" = "baseline" ]; then
            cp "$f" "$OUTPUT_DIR/images/linux-qt/"
        else
            cp "$f" "$OUTPUT_DIR/images/linux-qt/${theme_dir}-$(basename "$f")"
        fi
        linux_qt_count=$((linux_qt_count + 1))
    done
fi

# ── Collect TUI text snapshots ────────────────────────────────────
tui_count=0
tui_entries=""
if [ -d "$TUI_SNAPS" ]; then
    for f in "$TUI_SNAPS"/*.snap; do
        [ -f "$f" ] || continue
        tui_count=$((tui_count + 1))
        # Extract name from filename: snapshot_tests__<name>.snap -> <name>
        basename_f="$(basename "$f" .snap)"
        name="${basename_f#snapshot_tests__}"
        # Read content after the YAML frontmatter (skip lines until second ---)
        content=$(awk 'BEGIN{n=0} /^---$/{n++; next} n>=2{print}' "$f")
        # HTML-escape the content
        escaped=$(echo "$content" | sed 's/&/\&amp;/g; s/</\&lt;/g; s/>/\&gt;/g; s/"/\&quot;/g')
        tui_entries="$tui_entries<div class=\"card tui-card\"><h3>${name//_/ }</h3><pre class=\"tui-snap\">$escaped</pre></div>"
    done
fi

total=$((ios_count + macos_count + android_count + web_demo_count + linux_gtk_count + linux_qt_count + tui_count))
timestamp=$(date '+%Y-%m-%d %H:%M:%S')

# ── Generate HTML ─────────────────────────────────────────────────
cat > "$OUTPUT_FILE" << 'HTML_HEAD'
<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="UTF-8">
<meta name="viewport" content="width=device-width, initial-scale=1.0">
<title>Vauchi VRT Gallery</title>
<style>
  :root {
    --bg: #0d1117;
    --surface: #161b22;
    --border: #30363d;
    --text: #c9d1d9;
    --heading: #f0f6fc;
    --accent: #58a6ff;
    --ios: #007aff;
    --macos: #a2845e;
    --android: #3ddc84;
    --web-demo: #f97316;
    --linux-gtk: #4e9a06;
    --linux-qt: #729fcf;
    --tui: #a78bfa;
  }
  * { margin: 0; padding: 0; box-sizing: border-box; }
  body {
    font-family: -apple-system, BlinkMacSystemFont, 'Segoe UI', Helvetica, Arial, sans-serif;
    background: var(--bg);
    color: var(--text);
    line-height: 1.5;
  }
  header {
    background: var(--surface);
    border-bottom: 1px solid var(--border);
    padding: 1.5rem 2rem;
    display: flex;
    justify-content: space-between;
    align-items: center;
    position: sticky;
    top: 0;
    z-index: 100;
  }
  header h1 { color: var(--heading); font-size: 1.4rem; }
  .stats { display: flex; gap: 1rem; font-size: 0.85rem; }
  .stat { padding: 0.25rem 0.75rem; border-radius: 999px; border: 1px solid var(--border); }
  .stat-ios { border-color: var(--ios); color: var(--ios); }
  .stat-macos { border-color: var(--macos); color: var(--macos); }
  .stat-android { border-color: var(--android); color: var(--android); }
  .stat-web-demo { border-color: var(--web-demo); color: var(--web-demo); }
  .stat-linux-gtk { border-color: var(--linux-gtk); color: var(--linux-gtk); }
  .stat-linux-qt { border-color: var(--linux-qt); color: var(--linux-qt); }
  .stat-tui { border-color: var(--tui); color: var(--tui); }

  nav {
    background: var(--surface);
    border-bottom: 1px solid var(--border);
    padding: 0.5rem 2rem;
    display: flex;
    gap: 0.5rem;
    position: sticky;
    top: 65px;
    z-index: 99;
  }
  nav a {
    color: var(--text);
    text-decoration: none;
    padding: 0.4rem 1rem;
    border-radius: 6px;
    font-size: 0.85rem;
    transition: background 0.2s;
  }
  nav a:hover { background: var(--border); }

  main { padding: 2rem; max-width: 1600px; margin: 0 auto; }

  section { margin-bottom: 3rem; }
  section h2 {
    color: var(--heading);
    font-size: 1.2rem;
    margin-bottom: 1rem;
    padding-bottom: 0.5rem;
    border-bottom: 2px solid var(--border);
    display: flex;
    align-items: center;
    gap: 0.5rem;
  }
  .badge {
    font-size: 0.7rem;
    padding: 0.15rem 0.5rem;
    border-radius: 999px;
    font-weight: 600;
  }
  .badge-ios { background: var(--ios); color: #fff; }
  .badge-macos { background: var(--macos); color: #fff; }
  .badge-android { background: var(--android); color: #000; }
  .badge-web-demo { background: var(--web-demo); color: #000; }
  .badge-linux-gtk { background: var(--linux-gtk); color: #fff; }
  .badge-linux-qt { background: var(--linux-qt); color: #fff; }
  .badge-tui { background: var(--tui); color: #000; }

  .grid {
    display: grid;
    grid-template-columns: repeat(auto-fill, minmax(280px, 1fr));
    gap: 1rem;
  }
  .card {
    background: var(--surface);
    border: 1px solid var(--border);
    border-radius: 8px;
    overflow: hidden;
    transition: border-color 0.2s;
  }
  .card:hover { border-color: var(--accent); }
  .card h3 {
    padding: 0.6rem 0.8rem;
    font-size: 0.8rem;
    color: var(--text);
    border-bottom: 1px solid var(--border);
    text-transform: capitalize;
  }
  .card img {
    width: 100%;
    height: auto;
    display: block;
    cursor: zoom-in;
  }

  .tui-snap {
    font-family: 'SF Mono', 'Fira Code', 'JetBrains Mono', monospace;
    font-size: 0.6rem;
    line-height: 1.3;
    padding: 0.5rem;
    overflow-x: auto;
    background: #000;
    color: #c9d1d9;
    white-space: pre;
    min-height: 80px;
  }
  .tui-card { min-width: 350px; }

  .empty {
    text-align: center;
    padding: 2rem;
    color: #484f58;
    font-style: italic;
  }

  footer {
    text-align: center;
    padding: 2rem;
    color: #484f58;
    font-size: 0.8rem;
    border-top: 1px solid var(--border);
  }

  /* Lightbox */
  .lightbox {
    display: none;
    position: fixed;
    top: 0; left: 0; right: 0; bottom: 0;
    background: rgba(0,0,0,0.9);
    z-index: 1000;
    justify-content: center;
    align-items: center;
    cursor: zoom-out;
  }
  .lightbox.active { display: flex; }
  .lightbox img {
    max-width: 95vw;
    max-height: 95vh;
    object-fit: contain;
  }
</style>
</head>
<body>
HTML_HEAD

# Write header with stats
cat >> "$OUTPUT_FILE" << HTML_HEADER
<header>
  <h1>Vauchi VRT Gallery</h1>
  <div class="stats">
    <span class="stat stat-ios">iOS: $ios_count</span>
    <span class="stat stat-macos">macOS: $macos_count</span>
    <span class="stat stat-android">Android: $android_count</span>
    <span class="stat stat-web-demo">Web Demo: $web_demo_count</span>
    <span class="stat stat-linux-gtk">Linux GTK: $linux_gtk_count</span>
    <span class="stat stat-linux-qt">Linux Qt: $linux_qt_count</span>
    <span class="stat stat-tui">TUI: $tui_count</span>
  </div>
</header>
<nav>
  <a href="#ios">iOS</a>
  <a href="#macos">macOS</a>
  <a href="#android">Android</a>
  <a href="#web-demo">Web Demo</a>
  <a href="#linux-gtk">Linux GTK</a>
  <a href="#linux-qt">Linux Qt</a>
  <a href="#tui">TUI</a>
</nav>
<main>
HTML_HEADER

# ── iOS section ───────────────────────────────────────────────────
cat >> "$OUTPUT_FILE" << 'SECTION'
<section id="ios">
<h2><span class="badge badge-ios">iOS</span> swift-snapshot-testing</h2>
<div class="grid">
SECTION

if [ "$ios_count" -gt 0 ]; then
    for f in "$OUTPUT_DIR"/images/ios/*.png; do
        [ -f "$f" ] || continue
        name="$(basename "$f" .png)"
        # Convert testCamelCase to readable: strip 'test' prefix, add spaces before caps
        label=$(echo "${name%.1}" | sed 's/^test//' | sed 's/\([a-z]\)\([A-Z]\)/\1 \2/g')
        label=$(printf '%s' "$label" | sed 's/&/\&amp;/g; s/</\&lt;/g; s/>/\&gt;/g; s/"/\&quot;/g')
        echo "<div class=\"card\"><h3>$label</h3><img src=\"images/ios/$(basename "$f")\" alt=\"$label\" loading=\"lazy\" onclick=\"openLightbox(this)\"></div>" >> "$OUTPUT_FILE"
    done
else
    echo '<p class="empty">No iOS baselines found. Run snapshot tests in the ios/ repo first.</p>' >> "$OUTPUT_FILE"
fi

echo '</div></section>' >> "$OUTPUT_FILE"

# ── macOS section ────────────────────────────────────────────────
cat >> "$OUTPUT_FILE" << 'SECTION'
<section id="macos">
<h2><span class="badge badge-macos">macOS</span> swift-snapshot-testing</h2>
<div class="grid">
SECTION

if [ "$macos_count" -gt 0 ]; then
    for f in "$OUTPUT_DIR"/images/macos/*.png; do
        [ -f "$f" ] || continue
        name="$(basename "$f" .png)"
        label=$(echo "${name%.1}" | sed 's/^test//' | sed 's/\([a-z]\)\([A-Z]\)/\1 \2/g')
        label=$(printf '%s' "$label" | sed 's/&/\&amp;/g; s/</\&lt;/g; s/>/\&gt;/g; s/"/\&quot;/g')
        echo "<div class=\"card\"><h3>$label</h3><img src=\"images/macos/$(basename "$f")\" alt=\"$label\" loading=\"lazy\" onclick=\"openLightbox(this)\"></div>" >> "$OUTPUT_FILE"
    done
else
    echo '<p class="empty">No macOS baselines found. Run snapshot tests in the macos/ repo first.</p>' >> "$OUTPUT_FILE"
fi

echo '</div></section>' >> "$OUTPUT_FILE"

# ── Android section ───────────────────────────────────────────────
cat >> "$OUTPUT_FILE" << 'SECTION'
<section id="android">
<h2><span class="badge badge-android">Android</span> Compose Preview Screenshot Testing</h2>
<div class="grid">
SECTION

if [ "$android_count" -gt 0 ]; then
    for f in "$OUTPUT_DIR"/images/android/*.png; do
        [ -f "$f" ] || continue
        name="$(basename "$f" .png)"
        # Strip suffix like _73648466_0 and "Screenshot", add spaces
        label=$(echo "$name" | sed 's/_[0-9]*_[0-9]*$//' | sed 's/Screenshot$//' | sed 's/\([a-z]\)\([A-Z]\)/\1 \2/g')
        label=$(printf '%s' "$label" | sed 's/&/\&amp;/g; s/</\&lt;/g; s/>/\&gt;/g; s/"/\&quot;/g')
        echo "<div class=\"card\"><h3>$label</h3><img src=\"images/android/$(basename "$f")\" alt=\"$label\" loading=\"lazy\" onclick=\"openLightbox(this)\"></div>" >> "$OUTPUT_FILE"
    done
else
    echo '<p class="empty">No Android baselines found. Run ./gradlew updateDebugScreenshotTest in android/ first.</p>' >> "$OUTPUT_FILE"
fi

echo '</div></section>' >> "$OUTPUT_FILE"

# ── Web Demo section ─────────────────────────────────────────────
cat >> "$OUTPUT_FILE" << 'SECTION'
<section id="web-demo">
<h2><span class="badge badge-web-demo">Web Demo</span> Playwright</h2>
<div class="grid">
SECTION

if [ "$web_demo_count" -gt 0 ]; then
    for f in "$OUTPUT_DIR"/images/web-demo/*.png; do
        [ -f "$f" ] || continue
        name="$(basename "$f" .png)"
        label="${name//-/ }"
        label=$(printf '%s' "$label" | sed 's/&/\&amp;/g; s/</\&lt;/g; s/>/\&gt;/g; s/"/\&quot;/g')
        echo "<div class=\"card\"><h3>$label</h3><img src=\"images/web-demo/$(basename "$f")\" alt=\"$label\" loading=\"lazy\" onclick=\"openLightbox(this)\"></div>" >> "$OUTPUT_FILE"
    done
else
    echo '<p class="empty">No Web Demo baselines found. Run npx playwright test --update-snapshots in web-demo/ first.</p>' >> "$OUTPUT_FILE"
fi

echo '</div></section>' >> "$OUTPUT_FILE"

# ── Linux GTK section ────────────────────────────────────────────
cat >> "$OUTPUT_FILE" << 'SECTION'
<section id="linux-gtk">
<h2><span class="badge badge-linux-gtk">Linux GTK</span> AT-SPI Screenshots</h2>
<div class="grid">
SECTION

if [ "$linux_gtk_count" -gt 0 ]; then
    for f in "$OUTPUT_DIR"/images/linux-gtk/*.png; do
        [ -f "$f" ] || continue
        name="$(basename "$f" .png)"
        label="${name//_/ }"
        label=$(printf '%s' "$label" | sed 's/&/\&amp;/g; s/</\&lt;/g; s/>/\&gt;/g; s/"/\&quot;/g')
        echo "<div class=\"card\"><h3>$label</h3><img src=\"images/linux-gtk/$(basename "$f")\" alt=\"$label\" loading=\"lazy\" onclick=\"openLightbox(this)\"></div>" >> "$OUTPUT_FILE"
    done
else
    echo '<p class="empty">No Linux GTK baselines found. Run snapshot tests in the linux-gtk/ repo first.</p>' >> "$OUTPUT_FILE"
fi

echo '</div></section>' >> "$OUTPUT_FILE"

# ── Linux Qt section ─────────────────────────────────────────────
cat >> "$OUTPUT_FILE" << 'SECTION'
<section id="linux-qt">
<h2><span class="badge badge-linux-qt">Linux Qt</span> AT-SPI Screenshots</h2>
<div class="grid">
SECTION

if [ "$linux_qt_count" -gt 0 ]; then
    for f in "$OUTPUT_DIR"/images/linux-qt/*.png; do
        [ -f "$f" ] || continue
        name="$(basename "$f" .png)"
        label="${name//_/ }"
        label=$(printf '%s' "$label" | sed 's/&/\&amp;/g; s/</\&lt;/g; s/>/\&gt;/g; s/"/\&quot;/g')
        echo "<div class=\"card\"><h3>$label</h3><img src=\"images/linux-qt/$(basename "$f")\" alt=\"$label\" loading=\"lazy\" onclick=\"openLightbox(this)\"></div>" >> "$OUTPUT_FILE"
    done
else
    echo '<p class="empty">No Linux Qt baselines found. Run snapshot tests in the linux-qt/ repo first.</p>' >> "$OUTPUT_FILE"
fi

echo '</div></section>' >> "$OUTPUT_FILE"

# ── TUI section ───────────────────────────────────────────────────
cat >> "$OUTPUT_FILE" << 'SECTION'
<section id="tui">
<h2><span class="badge badge-tui">TUI</span> insta</h2>
<div class="grid">
SECTION

if [ "$tui_count" -gt 0 ]; then
    echo "$tui_entries" >> "$OUTPUT_FILE"
else
    echo '<p class="empty">No TUI baselines found. Run cargo test --test snapshot_tests in tui/ first.</p>' >> "$OUTPUT_FILE"
fi

echo '</div></section>' >> "$OUTPUT_FILE"

# ── Footer and scripts ────────────────────────────────────────────
cat >> "$OUTPUT_FILE" << HTML_FOOTER
</main>
<footer>
  Generated $timestamp &mdash; $total baselines across 7 platforms
</footer>
<div class="lightbox" id="lightbox" onclick="closeLightbox()">
  <img id="lightbox-img" src="" alt="">
</div>
<script>
function openLightbox(el) {
  document.getElementById('lightbox-img').src = el.src;
  document.getElementById('lightbox').classList.add('active');
}
function closeLightbox() {
  document.getElementById('lightbox').classList.remove('active');
}
document.addEventListener('keydown', function(e) {
  if (e.key === 'Escape') closeLightbox();
});
</script>
</body>
</html>
HTML_FOOTER

echo "VRT Gallery generated: $OUTPUT_FILE"
echo "  iOS: $ios_count | macOS: $macos_count | Android: $android_count | Web Demo: $web_demo_count | Linux GTK: $linux_gtk_count | Linux Qt: $linux_qt_count | TUI: $tui_count | Total: $total"

if [ "$NO_OPEN" = false ]; then
    if command -v open &> /dev/null; then
        open "$OUTPUT_FILE"
    elif command -v xdg-open &> /dev/null; then
        xdg-open "$OUTPUT_FILE"
    else
        echo "Open $OUTPUT_FILE in your browser."
    fi
fi
