<!-- SPDX-FileCopyrightText: 2026 Mattia Egloff <mattia.egloff@pm.me> -->
<!-- SPDX-License-Identifier: GPL-3.0-or-later -->

# Vauchi Dev Tools

[![Pipeline](https://vauchi.gitlab.io/scripts/badges/pipeline.svg)](https://gitlab.com/vauchi/scripts/-/pipelines)
[![REUSE](https://api.reuse.software/badge/gitlab.com/vauchi/scripts)](https://api.reuse.software/info/gitlab.com/vauchi/scripts)

Cross-project development tools, scripts, and utilities
for the Vauchi ecosystem.

## Requirements

### System Dependencies

| Tool | Required | Purpose |
| --- | --- | --- |
| Bash | Yes | All shell scripts |
| Git | Yes | Version control operations |
| Cargo/Rust | For Rust tests | Building and testing core |
| Python 3 | For coverage | Coverage scripts |
| bc | For coverage | Coverage math calculations |

### Optional Dependencies

| Tool | Purpose | Install |
| --- | --- | --- |
| Ollama | Local LLM | <https://ollama.ai> |
| qwen2:0.5b | Default LLM model | `ollama pull qwen2:0.5b` |
| cargo-llvm-cov | Coverage reports | `cargo install cargo-llvm-cov` |
| Xcode | iOS testing (macOS) | App Store |
| Android SDK | Android testing | Android Studio |

## Installation

```bash
# From workspace root
just install-hooks
```

Or manually:

```bash
./install-hooks.sh
```

## Structure

```text
scripts/
├── scripts/                  # Main development scripts
│   ├── dev/                  # Multi-instance testing
│   ├── e2e/                  # End-to-end test orchestration
│   ├── coverage/             # Coverage reporting tools
│   └── ide/                  # IDE setup scripts
├── hooks/                    # Git hooks
├── archive/                  # Deprecated scripts
├── clean.sh                  # Workspace cleanup
└── install-hooks.sh          # Git hook installer
```

## Key Scripts

### Workspace Management

| Script | Purpose |
| --- | --- |
| `setup-workspace.sh` | Clone all repositories |
| `sync-all.sh` | Pull/fetch all repos |
| `commit-interactive.sh` | Interactive multi-repo commit |

#### setup-workspace.sh

Clones all Vauchi repositories into a workspace:

```bash
# Clone public repos to ./vauchi-workspace
./scripts/setup-workspace.sh

# Custom workspace directory
./scripts/setup-workspace.sh -w ~/dev/vauchi

# Include private repos (requires access)
./scripts/setup-workspace.sh -a

# Environment variables
GITLAB_BASE=git@gitlab.com:vauchi  # default
WORKSPACE=./vauchi-workspace       # default
```

#### commit-interactive.sh

Interactive commit across multiple repositories:

```bash
./scripts/commit-interactive.sh

# Commands in interactive mode:
# a/A = Add all files & commit
# s/S = Stage interactively (git add -p)
# d/D = Show full diff
# c/C = Commit staged files only
# r/R = Reset/discard changes
# n/N = Skip this repo
# q/Q = Quit
```

### Testing

| Script | Purpose |
| --- | --- |
| `run-tests.sh` | Unified test runner |
| `tdd-setup.sh` | Configure TDD environment |
| `feature-audit.sh` | Feature-to-test gap analysis |

#### run-tests.sh

Run tests for specific platforms:

```bash
# All tests
./scripts/run-tests.sh

# Rust tests only
./scripts/run-tests.sh code

# Android tests
./scripts/run-tests.sh android

# iOS tests (macOS only)
./scripts/run-tests.sh ios -v

# Environment variables
WORKSPACE=.  # Workspace root
```

#### tdd-setup.sh

Configure strict Test-Driven Development environment:

```bash
# Enable strict TDD mode
./scripts/tdd-setup.sh --strict

# Enable 90% coverage verification
./scripts/tdd-setup.sh --coverage

# Install git hooks only
./scripts/tdd-setup.sh --hooks

# Run verification
./scripts/tdd-setup.sh --check
```

### Coverage

| Script | Purpose |
| --- | --- |
| `coverage-verify.sh` | Enforce 90% coverage |

#### coverage-verify.sh

Enforce minimum test coverage
(requires `cargo-llvm-cov` and `bc`):

```bash
# Basic coverage check
./scripts/coverage-verify.sh

# Options
./scripts/coverage-verify.sh --min-percent 90
./scripts/coverage-verify.sh --html
./scripts/coverage-verify.sh --json
./scripts/coverage-verify.sh --check-only
./scripts/coverage-verify.sh --crate vauchi-core
./scripts/coverage-verify.sh --fail-on-warn

# Reports output to: core/target/llvm-cov/html/
```

### Exploration

| Script | Purpose |
| --- | --- |
| `tell-me-about.sh` | LLM-assisted codebase search |

#### tell-me-about.sh

Quick codebase exploration using local LLM
(requires Ollama):

```bash
# Search for a topic
./scripts/tell-me-about.sh "iOS tests"
./scripts/tell-me-about.sh "recovery feature"
./scripts/tell-me-about.sh "crypto implementation"

# Environment variables
TELL_ME_MODEL=qwen2:0.5b  # default model
PROJECT_ROOT=.             # auto-detected
```

### Multi-Instance Testing (scripts/dev/)

Test sync/exchange between multiple simulated
"devices":

```bash
# Terminal 1: Start local relay
./scripts/dev/local-relay.sh

# Terminal 2: Alice
./scripts/dev/multi-cli.sh alice init "Alice Smith"
./scripts/dev/multi-cli.sh alice exchange start

# Terminal 3: Bob
./scripts/dev/multi-cli.sh bob init "Bob Jones"
./scripts/dev/multi-cli.sh bob exchange complete <qr-data>

# Clean up
./scripts/dev/cleanup.sh
```

| Script | Purpose |
| --- | --- |
| `_common.sh` | Shared variables and utilities |
| `local-relay.sh` | Start local relay (memory) |
| `local-relay-tls.sh` | Start local relay with TLS |
| `multi-cli.sh` | Run CLI with isolated data |
| `multi-tui.sh` | Run TUI with isolated data |
| `multi-desktop.sh` | Run desktop with isolated data |
| `cleanup.sh` | Clean test data and caches |
| `e2e-test-checklist.sh` | E2E testing checklist |

**Environment variables:**

```bash
VAUCHI_RELAY_PORT=8080       # default
VAUCHI_RELAY_HOST=127.0.0.1  # default
VAUCHI_TEST_DATA=./tmp/test-data
```

### Version Management

| Script | Purpose |
| --- | --- |
| `bump-version.sh` | Sync version across platforms |

#### bump-version.sh

Synchronize version across Rust, Android, and iOS:

```bash
./scripts/bump-version.sh 0.2.0
./scripts/bump-version.sh 1.0.0-beta.1

# Updates:
# - All Cargo.toml files
# - Android build.gradle.kts
# - iOS Info.plist
```

### Verification

| Script | Purpose |
| --- | --- |
| `verify-roadmap.sh` | Verify roadmap vs code |
| `check_inline_tests.sh` | Validate inline test markers |

## Git Hooks

Install with:

```bash
just install-hooks
# or
./install-hooks.sh
```

### Pre-commit checks

1. Rust formatting (`cargo fmt --check`)
2. Inline test markers validation
3. Potential secrets detection

### Pre-push checks

1. All tests pass
2. No sensitive files staged

## Just Commands

These scripts integrate with the workspace justfile:

```bash
just setup             # setup-workspace.sh
just build             # Build Rust workspace
just check             # Format, lint, test
just test              # run-tests.sh
just commit            # commit-interactive.sh
just tell-me-about     # tell-me-about.sh
just install-hooks     # install-hooks.sh
just dev-relay         # local-relay.sh
just dev-cli <name>    # multi-cli.sh
just dev-clean         # cleanup.sh
```

## CI Template Pitfalls

### Always use numeric project IDs in API calls

`CI_JOB_TOKEN` cannot resolve **private** project paths
(e.g. `vauchi%2Fprivate`) via the GitLab API — it returns
404 even with the inbound allowlist correctly configured.
Always use **numeric project IDs** for all cross-project
API access, regardless of visibility.

```yaml
# Bad — breaks for private projects
curl ".../projects/vauchi%2Fscripts/..."

# Good — works for all visibilities
curl ".../projects/77957857/..."
```

| Project | ID |
| --- | --- |
| vauchi/private | 77957469 |
| vauchi/scripts | 77957857 |

### Repository Tree API does not support CI_JOB_TOKEN

Even with numeric project IDs, the `/repository/tree`
endpoint returns 404 with `CI_JOB_TOKEN`. Use a sparse
`git clone` instead:

```bash
git clone --depth=1 --filter=blob:none --sparse \
  "https://gitlab-ci-token:${CI_JOB_TOKEN}@\
gitlab.com/vauchi/private.git" /tmp/repo
git -C /tmp/repo sparse-checkout set path/to/dir
```

## Archived Scripts

Deprecated scripts kept for reference in `archive/`:

- `android-emulators.sh` - Android emulator management
- `ios-simulators.sh` - iOS simulator management
- `tdd-template.sh` - Test template generator

## Related Repositories

| Repository | Description |
| --- | --- |
| [vauchi/core] | Core Rust library |
| [vauchi/features] | Gherkin feature specs |
| [vauchi/docs] | Documentation |

[vauchi/core]: https://gitlab.com/vauchi/core
[vauchi/features]: https://gitlab.com/vauchi/features
[vauchi/docs]: https://gitlab.com/vauchi/docs

## License

GPL-3.0-or-later
