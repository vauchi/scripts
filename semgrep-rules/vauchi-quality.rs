// SPDX-FileCopyrightText: 2026 Mattia Egloff <mattia.egloff@pm.me>
//
// SPDX-License-Identifier: GPL-3.0-or-later
//
// Fixture for `semgrep --test` against vauchi-quality.yml — every rule
// must fire on its `ruleid:` line and stay silent on `ok:` lines.
// Lives NEXT to the rule file (same stem) — the engine's --test mode
// pairs them by filename. Run: scripts/scripts/test-semgrep-rules.sh

// ── CC-03 ──────────────────────────────────────────────────────────────
fn cc03_cases(result: Result<u32, Error>, option: Option<u32>) {
    // ruleid: vauchi-cc03-assert-is-ok
    assert!(result.is_ok());
    // ruleid: vauchi-cc03-assert-is-err
    assert!(result.is_err());
    // ruleid: vauchi-cc03-assert-is-some
    assert!(option.is_some());
    // ok: vauchi-cc03-assert-is-ok
    assert_eq!(result.unwrap(), 3);
}

// ── CC-06 ──────────────────────────────────────────────────────────────
fn cc06_cases() {
    // ruleid: vauchi-cc06-no-sleep-in-tests
    std::thread::sleep(Duration::from_millis(500));
    // ruleid: vauchi-cc06-no-tokio-sleep-in-tests
    tokio::time::sleep(Duration::from_millis(500));
}

// ── ADR-030: no Transport generic on FFI-surface types ────────────────
// ruleid: vauchi-adr030-no-transport-generic
pub struct Vauchi<T: Transport> {
    sync: SendPhase<'static, T>,
}

// ruleid: vauchi-adr030-no-transport-generic
pub struct AppEngine<T: Transport> {
    inner: T,
}

// ok: vauchi-adr030-no-transport-generic
pub struct Vauchi {
    sync: Box<dyn Transport>,
}

// inner types keep the generic — the sanctioned static-dispatch home
// (SendPhase, formerly SyncController; retired by consolidation Step 3):
// ok: vauchi-adr030-no-transport-generic
pub struct SendPhase<'a, T: Transport> {
    transport: &'a T,
}

// ── ADR-043: DisplayHint is not screen data ────────────────────────────
pub struct ScreenModel {
    // ruleid: vauchi-adr043-no-displayhint-on-screenmodel
    pub display_hint: DisplayHint,
    pub title: String,
}

impl SettingsEngine {
    // construction parameter — the sanctioned use:
    // ok: vauchi-adr043-no-displayhint-on-screenmodel
    pub fn new(display_hint: DisplayHint) -> Self {
        Self {}
    }
}
