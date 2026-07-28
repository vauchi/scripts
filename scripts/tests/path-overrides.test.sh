#!/usr/bin/env bash
# SPDX-FileCopyrightText: 2026 Mattia Egloff <mattia.egloff@pm.me>
#
# SPDX-License-Identifier: GPL-3.0-or-later

# Regression suite for path-overrides.sh.
# Exercises apply / clean / idempotency. The check subcommand requires
# a real cargo workspace and is exercised end-to-end via session-init.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT="$SCRIPT_DIR/../path-overrides.sh"

pass=0
fail=0

mk_workspace() {
    local root="$1"
    mkdir -p "$root/cli" "$root/tui" "$root/linux-gtk" \
             "$root/web-demo/wasm" "$root/relay" "$root/e2e" \
             "$root/core/vauchi-core" "$root/core/vauchi-app" \
             "$root/core/vauchi-protocol" "$root/scripts/scripts"
    # Minimal Cargo.toml stubs — apply only appends, doesn't parse.
    for d in cli tui linux-gtk web-demo/wasm relay e2e; do
        printf '[package]\nname = "test-%s"\nversion = "0.1.0"\nedition = "2021"\n' \
            "$(echo "$d" | tr '/' '-')" > "$root/$d/Cargo.toml"
    done
    # Symlink the script into place so it discovers consumers
    # relative to the fixture root via cwd.
    cp "$SCRIPT" "$root/path-overrides.sh"
    chmod +x "$root/path-overrides.sh"
}

assert_exit() {
    local name="$1" want="$2" got="$3"
    if [[ "$want" == "$got" ]]; then
        printf '  PASS %s\n' "$name"
        pass=$((pass + 1))
    else
        printf '  FAIL %s — want exit %s, got %s\n' "$name" "$want" "$got" >&2
        fail=$((fail + 1))
    fi
}

assert_contains() {
    local name="$1" needle="$2" haystack="$3"
    if [[ "$haystack" == *"$needle"* ]]; then
        printf '  PASS %s\n' "$name"
        pass=$((pass + 1))
    else
        printf '  FAIL %s — missing %q\n    haystack: %s\n' "$name" "$needle" "$haystack" >&2
        fail=$((fail + 1))
    fi
}

assert_not_contains() {
    local name="$1" needle="$2" haystack="$3"
    if [[ "$haystack" != *"$needle"* ]]; then
        printf '  PASS %s\n' "$name"
        pass=$((pass + 1))
    else
        printf '  FAIL %s — unexpected %q\n    haystack: %s\n' "$name" "$needle" "$haystack" >&2
        fail=$((fail + 1))
    fi
}

# ── 1. Apply writes the fenced block to every consumer Cargo.toml ────
test_apply_writes_fence() {
    local root
    root="$(mktemp -d)"
    trap 'rm -rf "$root"' RETURN
    mk_workspace "$root"

    set +e
    out="$(cd "$root" && bash ./path-overrides.sh apply 2>&1)"
    rc=$?
    set -e

    assert_exit "apply exit 0" 0 "$rc"
    for d in cli tui linux-gtk relay e2e; do
        local cargo
        cargo=$(cat "$root/$d/Cargo.toml")
        assert_contains "$d has BEGIN fence" "# >>> setup-path-overrides BEGIN" "$cargo"
        assert_contains "$d has END fence" "# <<< setup-path-overrides END" "$cargo"
    done
    # Patches should reference the right relative paths
    assert_contains "cli patches vauchi-app to ../core" \
        '../core/vauchi-app' "$(cat "$root/cli/Cargo.toml")"
    # web-demo pins its core deps to an exact released version, which a
    # [patch] can never satisfy — cargo would discard the block and warn
    # "patch was not used in the crate graph" on every build. Guards
    # against re-adding it to CONSUMERS.
    assert_not_contains "web-demo/wasm is NOT patched (exact version pin)" \
        "# >>> setup-path-overrides BEGIN" \
        "$(cat "$root/web-demo/wasm/Cargo.toml")"
    assert_contains "e2e patches vauchi-relay" \
        'vauchi-relay = { path = "../relay" }' "$(cat "$root/e2e/Cargo.toml")"
    assert_contains "relay patches only vauchi-protocol" \
        'vauchi-protocol = { path = "../core/vauchi-protocol" }' \
        "$(cat "$root/relay/Cargo.toml")"
    assert_not_contains "relay does NOT patch vauchi-core" \
        'vauchi-core = { path' "$(cat "$root/relay/Cargo.toml")"
}

# ── 2. Apply is idempotent — re-running doesn't duplicate the block ──
test_apply_idempotent() {
    local root
    root="$(mktemp -d)"
    trap 'rm -rf "$root"' RETURN
    mk_workspace "$root"

    (cd "$root" && bash ./path-overrides.sh apply >/dev/null 2>&1)
    (cd "$root" && bash ./path-overrides.sh apply >/dev/null 2>&1)

    local count
    count=$(grep -c "# >>> setup-path-overrides BEGIN" "$root/cli/Cargo.toml")
    assert_exit "exactly one fence after double-apply" 1 "$count"
}

# ── 3. Clean removes the fenced block ─────────────────────────────────
test_clean_removes_fence() {
    local root
    root="$(mktemp -d)"
    trap 'rm -rf "$root"' RETURN
    mk_workspace "$root"

    (cd "$root" && bash ./path-overrides.sh apply >/dev/null 2>&1)
    set +e
    out="$(cd "$root" && bash ./path-overrides.sh clean 2>&1)"
    rc=$?
    set -e

    assert_exit "clean exit 0" 0 "$rc"
    for d in cli tui linux-gtk relay e2e; do
        assert_not_contains "$d fence stripped" \
            "# >>> setup-path-overrides BEGIN" \
            "$(cat "$root/$d/Cargo.toml")"
    done
}

# ── 4. Clean preserves user-authored Cargo.toml content ───────────────
test_clean_preserves_user_content() {
    local root
    root="$(mktemp -d)"
    trap 'rm -rf "$root"' RETURN
    mk_workspace "$root"

    # Use printf to avoid heredoc indentation issues with set -e.
    printf '%s\n' \
        '[package]' \
        'name = "test-cli"' \
        'version = "0.1.0"' \
        'edition = "2021"' \
        '' \
        '[dependencies]' \
        'serde = "1"' \
        > "$root/cli/Cargo.toml"
    local before
    before=$(cat "$root/cli/Cargo.toml")

    (cd "$root" && bash ./path-overrides.sh apply >/dev/null 2>&1)
    (cd "$root" && bash ./path-overrides.sh clean >/dev/null 2>&1)

    local after
    after=$(cat "$root/cli/Cargo.toml")
    # Compare line-for-line ignoring trailing whitespace
    if diff <(printf '%s' "$before") <(printf '%s' "$after") >/dev/null; then
        printf '  PASS user content preserved through apply→clean\n'
        pass=$((pass + 1))
    else
        printf '  FAIL user content changed by apply→clean\n' >&2
        printf '  diff:\n%s\n' "$(diff <(printf '%s' "$before") <(printf '%s' "$after"))" >&2
        fail=$((fail + 1))
    fi
}

# ── 5. Clean is idempotent — runs cleanly on a tree without fences ────
test_clean_idempotent() {
    local root
    root="$(mktemp -d)"
    trap 'rm -rf "$root"' RETURN
    mk_workspace "$root"

    set +e
    out="$(cd "$root" && bash ./path-overrides.sh clean 2>&1)"
    rc=$?
    set -e

    assert_exit "clean on no-fence exit 0" 0 "$rc"
    assert_contains "clean reports nothing to strip" "Nothing to strip" "$out"
}

# ── 6. Apply removes legacy .cargo/config.toml from previous recipe ──
test_apply_removes_legacy_config() {
    local root
    root="$(mktemp -d)"
    trap 'rm -rf "$root"' RETURN
    mk_workspace "$root"

    # Simulate the old (broken) layout
    mkdir -p "$root/cli/.cargo"
    printf '%s\n' \
        '# Auto-generated by: just setup-path-overrides' \
        "[patch.'https://gitlab.com/vauchi/core.git']" \
        'vauchi-core = { path = "../core/vauchi-core" }' \
        > "$root/cli/.cargo/config.toml"

    (cd "$root" && bash ./path-overrides.sh apply >/dev/null 2>&1)

    if [[ -f "$root/cli/.cargo/config.toml" ]]; then
        printf '  FAIL legacy .cargo/config.toml not removed\n' >&2
        fail=$((fail + 1))
    else
        printf '  PASS legacy .cargo/config.toml removed\n'
        pass=$((pass + 1))
    fi
}

# ── 7. Apply preserves a non-empty .cargo/config.toml (other settings) ─
test_apply_preserves_non_patch_config() {
    local root
    root="$(mktemp -d)"
    trap 'rm -rf "$root"' RETURN
    mk_workspace "$root"

    # User has unrelated cargo settings
    mkdir -p "$root/cli/.cargo"
    printf '%s\n' \
        '[build]' \
        'rustflags = ["-D", "warnings"]' \
        > "$root/cli/.cargo/config.toml"

    (cd "$root" && bash ./path-overrides.sh apply >/dev/null 2>&1)

    if [[ -f "$root/cli/.cargo/config.toml" ]] \
       && grep -q "rustflags" "$root/cli/.cargo/config.toml"; then
        printf '  PASS non-patch config preserved\n'
        pass=$((pass + 1))
    else
        printf '  FAIL non-patch config dropped\n' >&2
        fail=$((fail + 1))
    fi
}

# ── 8. Status reports whether any consumer carries the fence ─────────
# `just git sync` branches on this exit code to decide whether to
# restore overrides it stripped for the pull, so the 1-when-absent case
# matters as much as the 0-when-present one.
test_status_tracks_fence() {
    local root
    root="$(mktemp -d)"
    trap 'rm -rf "$root"' RETURN
    mk_workspace "$root"

    set +e
    (cd "$root" && bash ./path-overrides.sh status)
    local rc_clean=$?
    (cd "$root" && bash ./path-overrides.sh apply >/dev/null 2>&1)
    (cd "$root" && bash ./path-overrides.sh status)
    local rc_applied=$?
    (cd "$root" && bash ./path-overrides.sh clean >/dev/null 2>&1)
    (cd "$root" && bash ./path-overrides.sh status)
    local rc_stripped=$?
    set -e

    assert_exit "status exit 1 before apply" 1 "$rc_clean"
    assert_exit "status exit 0 after apply" 0 "$rc_applied"
    assert_exit "status exit 1 after clean" 1 "$rc_stripped"
}

# ── 9. Unknown subcommand exits 2 (usage error) ──────────────────────
test_unknown_subcommand() {
    set +e
    out="$(bash "$SCRIPT" frobnicate 2>&1)"
    rc=$?
    set -e
    assert_exit "unknown subcommand exit 2" 2 "$rc"
    assert_contains "usage hint shown" "Usage:" "$out"
}

# ── 10. clean --restore-lock reverts apply's Cargo.lock churn ────────
# Stripping the fence alone leaves Cargo.lock rewritten to local paths,
# which is enough to make `pull --rebase --autostash` fail to pop once
# main moves the lock. Plain `clean` must keep its narrower contract.
test_clean_restore_lock() {
    local root
    root="$(mktemp -d)"
    trap 'rm -rf "$root"' RETURN
    mk_workspace "$root"

    local repo="$root/cli"
    git -C "$repo" init -q
    printf 'committed-lock\n' > "$repo/Cargo.lock"
    git -C "$repo" add Cargo.toml Cargo.lock
    git -C "$repo" -c user.email=t@t -c user.name=t commit -qm init

    # Simulate apply: fence in Cargo.toml + rewritten Cargo.lock.
    (cd "$root" && bash ./path-overrides.sh apply >/dev/null 2>&1)
    printf 'rewritten-by-apply\n' > "$repo/Cargo.lock"

    (cd "$root" && bash ./path-overrides.sh clean >/dev/null 2>&1)
    assert_contains "plain clean leaves Cargo.lock churn" \
        'rewritten-by-apply' "$(cat "$repo/Cargo.lock")"

    (cd "$root" && bash ./path-overrides.sh apply >/dev/null 2>&1)
    printf 'rewritten-by-apply\n' > "$repo/Cargo.lock"

    (cd "$root" && bash ./path-overrides.sh clean --restore-lock >/dev/null 2>&1)
    assert_contains "clean --restore-lock reverts Cargo.lock" \
        'committed-lock' "$(cat "$repo/Cargo.lock")"
    assert_not_contains "clean --restore-lock still strips fence" \
        "# >>> setup-path-overrides BEGIN" "$(cat "$repo/Cargo.toml")"
}

# ── Run all ───────────────────────────────────────────────────────────

echo "── path-overrides.sh tests ──"
test_apply_writes_fence
test_apply_idempotent
test_clean_removes_fence
test_clean_preserves_user_content
test_clean_idempotent
test_apply_removes_legacy_config
test_apply_preserves_non_patch_config
test_status_tracks_fence
test_clean_restore_lock
test_unknown_subcommand

echo ""
echo "── results: $pass pass, $fail fail ──"
[[ "$fail" == 0 ]]
