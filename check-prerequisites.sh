#!/usr/bin/env bash
# SPDX-FileCopyrightText: 2026 Mattia Egloff <mattia.egloff@pm.me>
# SPDX-License-Identifier: GPL-3.0-or-later
#
# Check that required tools are installed before setup.
# Called by: just check-prerequisites

set -euo pipefail

# Ensure Git's utilities (uname, head, etc.) are on PATH on Windows
if [[ -d "/usr/bin" ]] && [[ ":$PATH:" != *":/usr/bin:"* ]]; then
    export PATH="/usr/bin:$PATH"
fi

MISSING=0
WARN=0

echo "=== Checking prerequisites ==="
echo ""

# Ensure ~/.cargo/bin is on PATH (common on fresh installs)
if [[ -d "$HOME/.cargo/bin" ]] && [[ ":$PATH:" != *":$HOME/.cargo/bin:"* ]]; then
    export PATH="$HOME/.cargo/bin:$PATH"
fi

# Detect platform using bash built-in $OSTYPE (no external commands)
case "$OSTYPE" in
    darwin*)  PLATFORM="macos" ;;
    linux*)   PLATFORM="linux" ;;
    msys*|cygwin*|mingw*) PLATFORM="windows" ;;
    *)       PLATFORM="unknown" ;;
esac

check_required() {
    local cmd="$1" purpose="$2" install_hint="$3"
    if command -v "$cmd" &>/dev/null; then
        local ver
        ver=$("$cmd" --version 2>/dev/null | head -1) || ver="(installed)"
        echo "  ✓ $cmd — $ver"
    else
        echo "  ✗ $cmd — MISSING ($purpose)"
        echo "    Install: $install_hint"
        MISSING=$((MISSING + 1))
    fi
}

check_recommended() {
    local cmd="$1" purpose="$2" install_hint="$3"
    if command -v "$cmd" &>/dev/null; then
        local ver
        ver=$("$cmd" --version 2>/dev/null | head -1) || ver="(installed)"
        echo "  ✓ $cmd — $ver"
    else
        echo "  ~ $cmd — not found ($purpose)"
        echo "    Install: $install_hint"
        WARN=$((WARN + 1))
    fi
}

# ── Required ──────────────────────────────────────────────────────
echo "── Required ──"

check_required "git" "version control" \
    "https://git-scm.com/downloads"

case "$PLATFORM" in
    windows) RUSTUP_HINT="winget install Rustlang.Rustup  (or https://rustup.rs)" ;;
    *)       RUSTUP_HINT="curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh" ;;
esac

check_required "rustup" "Rust toolchain manager" "$RUSTUP_HINT"
check_required "cargo" "Rust build tool" "install via rustup (above)"
check_required "rustc" "Rust compiler" "install via rustup (above)"

case "$PLATFORM" in
    macos)   JUST_HINT="brew install just" ;;
    linux)   JUST_HINT="cargo install just  (or https://just.systems/man/en/packages.html)" ;;
    windows) JUST_HINT="winget install Casey.Just  (or cargo install just)" ;;
    *)       JUST_HINT="cargo install just" ;;
esac
check_required "just" "command runner (all build/test/deploy recipes)" "$JUST_HINT"

echo ""

# ── Recommended ───────────────────────────────────────────────────
echo "── Recommended ──"

case "$PLATFORM" in
    macos)
        check_recommended "glab" "GitLab CLI for MRs and pipelines" \
            "brew install glab"
        check_recommended "node" "JavaScript runtime (web-demo, docs)" \
            "brew install node"
        check_recommended "jq" "JSON processing" \
            "brew install jq"
        ;;
    linux)
        check_recommended "glab" "GitLab CLI for MRs and pipelines" \
            "https://gitlab.com/gitlab-org/cli#installation"
        check_recommended "node" "JavaScript runtime (web-demo, docs)" \
            "https://nodejs.org/en/download"
        check_recommended "jq" "JSON processing" \
            "sudo apt install jq  (or your package manager)"
        ;;
    windows)
        check_recommended "glab" "GitLab CLI for MRs and pipelines" \
            "winget install glab  (or scoop install glab)"
        check_recommended "node" "JavaScript runtime (web-demo, docs)" \
            "winget install OpenJS.NodeJS.LTS"
        check_recommended "jq" "JSON processing" \
            "winget install jqlang.jq  (or scoop install jq)"
        ;;
    *)
        check_recommended "glab" "GitLab CLI for MRs and pipelines" \
            "https://gitlab.com/gitlab-org/cli#installation"
        check_recommended "node" "JavaScript runtime (web-demo, docs)" \
            "https://nodejs.org/en/download"
        check_recommended "jq" "JSON processing" \
            "https://jqlang.github.io/jq/download/"
        ;;
esac

# ── Linting tools (used by gate-push hook) ────────────────────────
echo ""
echo "── Linting tools (gate-push hook) ──"

case "$PLATFORM" in
    macos)
        check_recommended "markdownlint" "markdown linting (gate-push)" \
            "npm i -g markdownlint-cli"
        check_recommended "typos" "spellcheck (gate-push)" \
            "cargo binstall typos-cli  (or cargo install typos-cli)"
        check_recommended "reuse" "SPDX header compliance (gate-push)" \
            "brew install reuse  (or pipx install reuse)"
        ;;
    linux)
        check_recommended "markdownlint" "markdown linting (gate-push)" \
            "npm i -g markdownlint-cli"
        check_recommended "typos" "spellcheck (gate-push)" \
            "cargo binstall typos-cli  (or cargo install typos-cli)"
        check_recommended "reuse" "SPDX header compliance (gate-push)" \
            "pipx install reuse"
        ;;
    windows)
        check_recommended "markdownlint" "markdown linting (gate-push)" \
            "npm i -g markdownlint-cli"
        check_recommended "typos" "spellcheck (gate-push)" \
            "cargo install typos-cli"
        check_recommended "reuse" "SPDX header compliance (gate-push)" \
            "pip install reuse"
        ;;
    *)
        check_recommended "markdownlint" "markdown linting (gate-push)" \
            "npm i -g markdownlint-cli"
        check_recommended "typos" "spellcheck (gate-push)" \
            "cargo install typos-cli"
        check_recommended "reuse" "SPDX header compliance (gate-push)" \
            "pipx install reuse"
        ;;
esac

echo ""

# Python — needed for mdplan
if command -v pipx &>/dev/null; then
    echo "  ✓ pipx — $(pipx --version 2>/dev/null || echo installed)"
elif command -v pip3 &>/dev/null; then
    echo "  ✓ pip3 — $(pip3 --version 2>/dev/null | head -1)"
elif command -v pip &>/dev/null; then
    echo "  ✓ pip — $(pip --version 2>/dev/null | head -1)"
else
    echo "  ~ pip/pipx — not found (needed for mdplan CLI)"
    case "$PLATFORM" in
        macos)   echo "    Install: brew install pipx" ;;
        linux)   echo "    Install: sudo apt install pipx  (or your package manager)" ;;
        windows) echo "    Install: winget install Python.Python.3  (includes pip)" ;;
        *)       echo "    Install: https://pip.pypa.io/en/stable/installation/" ;;
    esac
    WARN=$((WARN + 1))
fi

echo ""

# ── Quick install ─────────────────────────────────────────────────
if [[ "$MISSING" -gt 0 || "$WARN" -gt 0 ]]; then
    echo "── Quick install ──"
    echo ""
    case "$PLATFORM" in
        macos)
            echo "  # Required + recommended (Homebrew):"
            echo "  brew install rustup node glab jq pipx reuse"
            echo "  rustup-init -y && source \"\$HOME/.cargo/env\""
            echo "  cargo binstall typos-cli && npm i -g markdownlint-cli"
            ;;
        linux)
            echo "  # Required (rustup):"
            echo "  curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh"
            echo "  source \"\$HOME/.cargo/env\""
            echo ""
            echo "  # Recommended (apt — adjust for your distro):"
            echo "  sudo apt install -y nodejs npm jq pipx"
            echo "  pipx install reuse && cargo binstall typos-cli && npm i -g markdownlint-cli"
            echo "  # glab: https://gitlab.com/gitlab-org/cli#installation"
            ;;
        windows)
            echo "  # Required + recommended (winget — run in PowerShell):"
            echo "  winget install Rustlang.Rustup"
            echo "  winget install GitLab.Glab OpenJS.NodeJS.LTS jqlang.jq"
            echo ""
            echo "  Restart your terminal after installing to update PATH."
            ;;
    esac
    echo ""
fi

# ── Summary ───────────────────────────────────────────────────────
if [[ "$MISSING" -gt 0 ]]; then
    echo "✗ $MISSING required tool(s) missing — install them and re-run: just setup"
    exit 1
elif [[ "$WARN" -gt 0 ]]; then
    echo "✓ All required tools present ($WARN recommended tool(s) missing — setup will continue)"
else
    echo "✓ All tools present"
fi
