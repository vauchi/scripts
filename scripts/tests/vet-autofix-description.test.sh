#!/usr/bin/env bash
# SPDX-FileCopyrightText: 2026 Mattia Egloff <mattia.egloff@pm.me>
#
# SPDX-License-Identifier: GPL-3.0-or-later

# vet-autofix-description.test.sh — Pins the description-builder
# behaviour for the cargo-vet auto-sync MR body. Origin:
# `_private/docs/problems/2026-05-03-vet-autosync-stale-snapshots`
# Phase 1 (G2) — surface stealth UI churn in the auto-sync MR
# description so reviewers see the lockfile bump's UI impact before
# CI flags missing snapshot regen.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT="$SCRIPT_DIR/../ci/vet-autofix-description.sh"

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

# ── No rev pair → empty (caller didn't detect a bump) ──────────
assert_eq "missing both revs → empty" \
    '' \
    "$(printf '' | "$SCRIPT" '' '')"

assert_eq "missing OLD_REV → empty" \
    '' \
    "$(printf '' | "$SCRIPT" '' 'newdeadbeef')"

assert_eq "missing NEW_REV → empty" \
    '' \
    "$(printf '' | "$SCRIPT" 'olddeadbeef' '')"

# ── Same rev → empty (no actual bump) ──────────────────────────
assert_eq "same rev → empty" \
    '' \
    "$(printf 'core/vauchi-app/src/ui/settings.rs\n' | "$SCRIPT" 'abcd1234' 'abcd1234')"

# ── Different revs, empty stdin → empty (no UI files) ──────────
assert_eq "different revs, no UI files → empty" \
    '' \
    "$(printf '' | "$SCRIPT" 'abcd1234' 'feed5678')"

# ── Different revs + one UI file → formatted block ─────────────
got=$(printf 'core/vauchi-app/src/ui/settings.rs\n' \
    | "$SCRIPT" 'abcd1234567890' 'feed567890abcd')
want=$(cat <<'EOF'

---

⚠ **Lockfile also bumps `vauchi-core`: `abcd1234` → `feed5678`**

UI files touched between revs (`core/vauchi-app/src/ui/`):

- `core/vauchi-app/src/ui/settings.rs`

Snapshot regen may be required if any of the above changed
`ScreenModel` shape. Run the repo's snapshot-record command
(e.g. `cargo insta test --accept`) before merging if CI flags
snapshot drift.
EOF
)
assert_eq "diff revs, one UI file → block" "$want" "$got"

# ── Multiple UI files preserved in order ───────────────────────
got=$(printf 'core/vauchi-app/src/ui/settings.rs\ncore/vauchi-app/src/ui/components.rs\n' \
    | "$SCRIPT" 'abcd1234567890' 'feed567890abcd')
want=$(cat <<'EOF'

---

⚠ **Lockfile also bumps `vauchi-core`: `abcd1234` → `feed5678`**

UI files touched between revs (`core/vauchi-app/src/ui/`):

- `core/vauchi-app/src/ui/settings.rs`
- `core/vauchi-app/src/ui/components.rs`

Snapshot regen may be required if any of the above changed
`ScreenModel` shape. Run the repo's snapshot-record command
(e.g. `cargo insta test --accept`) before merging if CI flags
snapshot drift.
EOF
)
assert_eq "diff revs, two UI files → block" "$want" "$got"

# ── Stdin filtering: helper trusts caller. Non-UI paths still
# render — the caller is responsible for filtering before piping.
# This pins the contract: the helper does not silently drop rows.
got=$(printf 'README.md\n' | "$SCRIPT" 'abcd1234567890' 'feed567890abcd')
want=$(cat <<'EOF'

---

⚠ **Lockfile also bumps `vauchi-core`: `abcd1234` → `feed5678`**

UI files touched between revs (`core/vauchi-app/src/ui/`):

- `README.md`

Snapshot regen may be required if any of the above changed
`ScreenModel` shape. Run the repo's snapshot-record command
(e.g. `cargo insta test --accept`) before merging if CI flags
snapshot drift.
EOF
)
assert_eq "helper trusts caller-filtered list" "$want" "$got"

# ── Short revs (< 8 chars) pass through unchanged ──────────────
got=$(printf 'core/vauchi-app/src/ui/settings.rs\n' | "$SCRIPT" 'abc' 'def')
want=$(cat <<'EOF'

---

⚠ **Lockfile also bumps `vauchi-core`: `abc` → `def`**

UI files touched between revs (`core/vauchi-app/src/ui/`):

- `core/vauchi-app/src/ui/settings.rs`

Snapshot regen may be required if any of the above changed
`ScreenModel` shape. Run the repo's snapshot-record command
(e.g. `cargo insta test --accept`) before merging if CI flags
snapshot drift.
EOF
)
assert_eq "short revs pass through" "$want" "$got"

echo ""
echo "── ${pass} passed, ${fail} failed ──"
[[ $fail -eq 0 ]]
