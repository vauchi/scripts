# CLAUDE.md - Dev Tools

Cross-project development tools, scripts, and utilities.

## Structure

- `scripts/` — General dev scripts (commit, sync, coverage, tell-me-about)
- `hooks/` — Git hooks for all repos (install with `just install-hooks`)
- `ci-templates/` — Shared GitLab CI templates
- `archive/` — Deprecated scripts

## Rules

- Scripts: `#!/usr/bin/env bash`, `set -euo pipefail`, executable, usage comments at top
- **pre-commit** hook blocks: formatting errors, inline test markers, potential secrets
- **pre-push** hook blocks: lint/test failures (Rust, iOS, Android)
