<!-- SPDX-FileCopyrightText: 2026 Mattia Egloff <mattia.egloff@pm.me> -->
<!-- SPDX-License-Identifier: GPL-3.0-or-later -->

# CLAUDE.md - Dev Tools

Cross-project development tools, scripts, and utilities.

## Structure

| Path | Purpose |
|------|---------|
| `scripts/` | General dev scripts |
| `scripts/coverage/` | Coverage reporting |
| `scripts/dev/` | Multi-instance testing |
| `scripts/ide/` | IDE setup scripts |
| `hooks/` | Git hooks for all repos |
| `archive/` | Deprecated scripts |

## Key Scripts

| Script | Purpose | Just Command |
|--------|---------|--------------|
| `commit-interactive.sh` | Interactive commit across repos | `just commit` |
| `sync-all.sh` | Pull/fetch all repos | `just pull-all` |
| `tell-me-about.sh` | Explore codebase with local LLM | `just tell-me-about` |

## Multi-Instance Testing (`scripts/dev/`)

For testing sync/exchange between multiple "devices":

| Script | Purpose | Just Command |
|--------|---------|--------------|
| `local-relay.sh` | Start local relay (memory storage) | `just dev-relay` |
| `multi-cli.sh` | Run CLI with isolated data | `just dev-cli <name>` |
| `multi-tui.sh` | Run TUI with isolated data | `just dev-tui <name>` |
| `cleanup.sh` | Clean test data and caches | `just dev-clean` |

## Git Hooks

Install with `just install-hooks`. Installs to all sub-repos (core, cli, tui, relay, desktop, e2e, ios, android).

**pre-commit** — blocks commit on:
- Rust formatting
- Inline test markers (missing `INLINE_TEST_REQUIRED`)
- Potential secrets

**pre-push** — blocks push on (repo-type dependent):
- Rust repos: `just fmt <repo>`, `just lint <repo>`, `just test <repo>` (or raw: `cargo fmt --check`, `cargo clippy -D warnings`, `cargo test`)
- iOS: `swiftformat --lint`, `swiftlint --strict`
- Android: `compileDebugKotlin`, `gradle lint`

## See Also

- Root justfile: `../justfile`
- Feature specs: `../features/`
