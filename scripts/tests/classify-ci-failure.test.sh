#!/usr/bin/env bash
# SPDX-FileCopyrightText: 2026 Mattia Egloff <mattia.egloff@pm.me>
# SPDX-License-Identifier: GPL-3.0-or-later
#
# Test runner for `scripts/scripts/classify-ci-failure.sh`.
#
# The classifier turns a CI job trace into a deterministic {category, fix,
# escalate} verdict by regex, so `/ci-fix` spends NO model tokens
# re-classifying the common failures — the model is reserved for the
# actual fix and for the unknown tail (escalate=true). This test pins the
# signature→category mapping (the documented ci-fix table) and the
# unknown-escalation contract.
#
# Run: bash scripts/scripts/tests/classify-ci-failure.test.sh

set -euo pipefail

set -uo pipefail

DIR="$(cd "$(dirname "$0")/.." && pwd)"
SCRIPT="$DIR/classify-ci-failure.sh"

if [[ ! -x "$SCRIPT" ]]; then
    echo "FATAL: $SCRIPT not executable (not implemented yet — RED)" >&2
    exit 1
fi

PASS=0
FAIL=0

# classify <trace-text> -> prints JSON verdict
classify() { printf '%s\n' "$1" | bash "$SCRIPT"; }

classify_with_failure_reason() {
    local trace="$1" failure_reason="$2"
    printf '%s\n' "$trace" | bash "$SCRIPT" --failure-reason "$failure_reason"
}

expect_category() {
    local name="$1" trace="$2" want="$3"
    local got
    got=$(classify "$trace" | jq -r '.category' 2>/dev/null)
    if [[ "$got" == "$want" ]]; then
        printf '  PASS  %s\n' "$name"; PASS=$((PASS + 1))
    else
        printf '  FAIL  %s\n    want category=%s, got=%s\n' "$name" "$want" "$got"
        FAIL=$((FAIL + 1))
    fi
}

expect_escalate() {
    local name="$1" trace="$2" want="$3"
    local got
    got=$(classify "$trace" | jq -r '.escalate' 2>/dev/null)
    if [[ "$got" == "$want" ]]; then
        printf '  PASS  %s\n' "$name"; PASS=$((PASS + 1))
    else
        printf '  FAIL  %s\n    want escalate=%s, got=%s\n' "$name" "$want" "$got"
        FAIL=$((FAIL + 1))
    fi
}

expect_fix() {
    local name="$1" trace="$2" want="$3"
    local got
    got=$(classify "$trace" | jq -r '.fix' 2>/dev/null)
    if [[ "$got" == "$want" ]]; then
        printf '  PASS  %s\n' "$name"; PASS=$((PASS + 1))
    else
        printf '  FAIL  %s\n    want fix=%s, got=%s\n' "$name" "$want" "$got"
        FAIL=$((FAIL + 1))
    fi
}

expect_category_with_failure_reason() {
    local name="$1" trace="$2" failure_reason="$3" want="$4"
    local got
    got=$(classify_with_failure_reason "$trace" "$failure_reason" | jq -r '.category' 2>/dev/null)
    if [[ "$got" == "$want" ]]; then
        printf '  PASS  %s\n' "$name"; PASS=$((PASS + 1))
    else
        printf '  FAIL  %s\n    want category=%s, got=%s\n' "$name" "$want" "$got"
        FAIL=$((FAIL + 1))
    fi
}

expect_category "C FFI cross-compile" \
    "  = note: fatal error: 'openssl/ssl.h' file not found" "c-ffi-cross"
expect_category "dependency resolution" \
    "error: failed to select a version for \`libc\`" "dep-resolution"
expect_category "cargo-deny rejects duplicate contract versions" \
    "2026-11-13T08:30:54Z 01E error[duplicate]: found 2 duplicate entries for crate 'vauchi-contract'" \
    "dep-resolution"
expect_category "cargo-deny rejects an unmaintained dependency" \
    "error[unmaintained]: chrono is unmaintained" "dep-resolution"
expect_escalate "cargo-deny duplicate failure is actionable" \
    "error[duplicate]: found 2 duplicate entries for crate 'vauchi-contract'" "false"
expect_category "cargo-deny duplicate warning is not a dependency failure" \
    "warning[duplicate]: found 2 duplicate entries for crate 'console'" "unknown"
expect_category "pinned release cohort mismatch" \
    "FAIL: relay/Cargo.toml pins Core crates at another tag than the set's v0.99.1:" "dep-resolution"
expect_category "lockfile release cohort mismatch" \
    "FAIL: Cargo.lock resolves Core crates at another tag than the set's v0.106.2:" "dep-resolution"
expect_category "cohort updater rejects a foreign lock source" \
    "2026-11-25T02:25:39Z 01E cohort: ERROR: untrusted lockfile source" "dep-resolution"
expect_category "benchmark regression gate" \
    "ERROR: Performance regression > 100% detected!" "test-failure"
expect_category "duplication clone-count regression" \
    "2026-11-26T06:37:08Z 01O jscpd-new-clones: duplication grew: clones grew from 380 to 382" "lint"
expect_category "duplication line-count regression" \
    "jscpd-new-clones: duplication grew: duplicated lines grew from 8600 to 8626" "lint"
expect_escalate "duplication regression does not need manual classification" \
    "jscpd-new-clones: duplication grew: clones grew from 380 to 382" "false"
expect_category "clean duplication summary stays unknown" \
    "jscpd-new-clones: 0 new, of 0 jscpd flagged by text (allowed: 0)" "unknown"
expect_category "fractional benchmark regression threshold" \
    "ERROR: Performance regression > 12.5% detected!" "test-failure"
expect_category "benchmark comparison without a failed gate stays unknown" \
    "Performance has regressed." "unknown"
expect_category "Git checkout DNS failure" \
    "fatal: unable to access 'https://gitlab.com/vauchi/linux-qt.git/': Could not resolve host: gitlab.com" \
    "transient-network"
expect_escalate "Git checkout DNS failure does not escalate" \
    "fatal: Could not resolve host: gitlab.com" "false"
expect_category "Git checkout connection failure" \
    "2026-11-16T06:32:29Z 01E fatal: unable to access 'https://gitlab.com/vauchi/core.git/': Failed to connect to gitlab.com:443 after 134163 ms: Could not connect to server" \
    "transient-network"
expect_category "Git checkout connection failure with explicit port" \
    "fatal: unable to access 'https://gitlab.com/vauchi/core.git/': Failed to connect to gitlab.com port 443 after 134163 ms: Could not connect to server" \
    "transient-network"
expect_escalate "Git checkout connection failure does not escalate" \
    "fatal: unable to access 'https://gitlab.com/vauchi/core.git/': Failed to connect to gitlab.com:443 after 134163 ms: Could not connect to server" \
    "false"
expect_category "application connection message is not Git transport" \
    "test fixture: Failed to connect to gitlab.com:443 after 134163 ms: Could not connect to server" \
    "unknown"
expect_category "sccache daemon startup timeout" \
    "sccache: error: Timed out waiting for server startup" "runner-infrastructure"
expect_category "npm dependency audit" \
    "1 moderate severity vulnerability" "dep-resolution"
expect_category "cargo dependency audit" \
    "error: 4 vulnerabilities found!" "dep-resolution"
expect_escalate "cargo dependency audit does NOT escalate" \
    "error: 1 vulnerability found!" "false"
expect_category "cargo audit denied maintenance warning" \
    "error: 1 denied warning found!" "dep-resolution"
expect_category "cargo audit denied multiple warnings" \
    "2026-11-05T13:51:58.873257Z 01E error: 2 denied warnings found!" "dep-resolution"
expect_category "an allowed maintenance warning does not fail the audit" \
    "Warning: unmaintained" "unknown"
expect_category "missing tool (bash)" \
    "/bin/sh: cargo-nextest: command not found" "missing-tool"
expect_category "missing tool (busybox)" \
    "sh: mold: not found" "missing-tool"
expect_category "Python before 3.11 lacks tomllib" \
    "ModuleNotFoundError: No module named 'tomllib'" "toolchain-compatibility"
expect_category "just script feature flag missing in CI" \
    "error: The \`[script]\` attribute is currently unstable. Invoke \`just\` with \`--unstable\`." \
    "just-syntax"
expect_category "stale shared CI template tag" \
    '.gitlab-ci.yml: VSP01: pinned ci-templates-v2026.10.08 is not among the latest ci-template tags' \
    "lint"
expect_category "successful freshness check is not a stale pin" \
    '.gitlab-ci.yml: VSP01 check passed, no stale ci-template pins' "unknown"
expect_category "verified helper checksum mismatch" \
    '2026-11-12T07:22:38Z 01E sha256sum: WARNING: 1 computed checksum did NOT match' \
    "artifact-integrity"
expect_escalate "verified helper checksum mismatch does not escalate" \
    'sha256sum: WARNING: 1 computed checksum did NOT match' "false"
expect_fix "checksum mismatch preserves integrity verification" \
    'sha256sum: WARNING: 1 computed checksum did NOT match' \
    "Verify the downloaded bytes against the pinned source ref, then correct the ref or expected digest; never bypass checksum verification."
expect_category "verified helper checksum success is not a mismatch" \
    'push-coverage.sh: OK' "unknown"
expect_category "missing checksum verifier remains a missing tool" \
    'sha256sum: command not found' "missing-tool"
expect_escalate "missing tomllib does NOT escalate" \
    "2026-11-03T12:00:00Z 01E ModuleNotFoundError: No module named 'tomllib'" "false"
expect_fix "missing tomllib names the runtime or backport fix" \
    "ModuleNotFoundError: No module named 'tomllib'" \
    "Use Python 3.11+ or install a pinned tomli backport and fall back to it when tomllib is unavailable."
expect_category "unrelated Python module is not a tomllib runtime mismatch" \
    "ModuleNotFoundError: No module named 'other_module'" "unknown"
expect_category "timeout" \
    "ERROR: Job exceeded maximum timeout of 3600 seconds" "timeout"
expect_category "runner package-index DNS failure" \
    "WARNING: fetching https://dl-cdn.alpinelinux.org/alpine/v3.24/main/x86_64/APKINDEX.tar.gz: DNS: transient error (try again later)" \
    "transient-network"
expect_escalate "runner package-index DNS failure does NOT escalate" \
    "WARNING: fetching https://dl-cdn.alpinelinux.org/alpine/v3.24/main/x86_64/APKINDEX.tar.gz: DNS: transient error (try again later)" \
    "false"
expect_category "proxy target health timeout" \
    "Error: target failed to become healthy within configured timeout (30s)" \
    "target-health"
expect_escalate "proxy target health timeout does NOT escalate" \
    "Error: target failed to become healthy within configured timeout (30s)" \
    "false"
expect_fix "proxy target health timeout checks reachability before duration" \
    "Error: target failed to become healthy within configured timeout (30s)" \
    "Inspect the proxy target address, network, port, and health path; only raise the deploy timeout when a valid target genuinely starts slowly."
expect_category "GitLab execution timeout" \
    "ERROR: Job failed: execution took longer than 10m0s seconds" "timeout"
expect_category "branch protection" \
    "remote: GitLab: pre-receive hook declined" "branch-protection"
expect_category "rust compile error" \
    "error[E0433]: failed to resolve: use of undeclared crate" "compile-error"
expect_category "Swift missing argument compile error" \
    "BleExchangeService.swift:209:80: error: missing argument for parameter 'direction' in call" \
    "compile-error"
expect_category "Kotlin missing argument compile error" \
    "CoreAppViewModel.kt:397:52 No value passed for parameter 'direction'." \
    "compile-error"
expect_category "Swift missing symbol compile error" \
    "PresentationStateTests.swift:44:17: error: cannot find 'presentationContractFixtureJson' in scope" \
    "compile-error"
expect_category "Rust unresolved import compile error" \
    "error[E0432]: unresolved import \`vauchi_app::ui::presentation_contract_fixture_json\`" \
    "compile-error"
expect_category "native linker compile error" \
    "undefined reference to vauchi_presentation_contract_fixture" \
    "compile-error"
expect_category "Windows native library artifact gap" \
    "System.DllNotFoundException : Unable to load DLL 'vauchi_cabi' or one of its dependencies" \
    "artifact-gap"
expect_category "test failure" \
    "test result: FAILED. 3 passed; 1 failed" "test-failure"
expect_category "C++ assertion with GitLab timestamp" \
    '2026-11-06T14:58:56Z 01O file_picker_test.cpp:169: Assertion events.size() == 1 failed.' \
    "test-failure"
expect_escalate "C++ assertion does not escalate" \
    'file_picker_test.cpp:169: Assertion events.size() == 1 failed.' "false"
expect_category "pytest assertion with GitLab timestamp" \
    "2026-10-26T15:43:09.706888Z 01O FAILED test_presentation_controls.py::test_editable_input - AssertionError: assert '' == 'Original text'" \
    "test-failure"
expect_category "pytest fixture failure" \
    "ERROR tests/atspi/test_fixture_a11y.py::test_label - AssertionError: missing widget" \
    "test-failure"
expect_category "pytest passing summary is not a failure" \
    "112 passed, 9 deselected in 58.02s" "unknown"
expect_category "custom runner nonzero exit" \
    "FAIL: iPhone onboarding without Home markers must fail; got exit 127" \
    "test-failure"
expect_category "hook self-test suite failure" \
    "FAILED: 1 hook self-test suite(s) red." "test-failure"
expect_category "runner infrastructure self-test assertion failure" \
    "FAILED: 1 runner-infrastructure self-test suite(s) red." "test-failure"
expect_category "timestamped runner infrastructure self-test failure" \
    "2026-11-16T08:00:00Z 01O FAILED: 12 runner-infrastructure self-test suite(s) red." \
    "test-failure"
expect_escalate "runner self-test failure needs no signature escalation" \
    "FAILED: 1 runner-infrastructure self-test suite(s) red." "false"
expect_category "runner self-test success is not a failure" \
    "FAILED: 0 runner-infrastructure self-test suite(s) red." "unknown"
expect_category "private workspace discovery failure" \
    "ValueError: expected _private git common directory, got /builds/vauchi/private" \
    "test-failure"
expect_category "lychee missing local link" \
    "[ERROR] file:///builds/vauchi/private/.codex/docs/reference/pilot/README.md | Cannot find file: File not found. Check if file exists and path is correct" "lint"
expect_escalate "lychee missing local link does not escalate" \
    "2026-11-02T15:00:52Z 01O [ERROR] file:///builds/vauchi/private/missing.md | Cannot find file: File not found." "false"
expect_category "lychee success does not invent a failure" \
    "3935 Total (in 0s) 1381 OK 0 Errors 2554 Excluded" "unknown"
expect_category "clippy/lint" \
    "error: this \`if\` has identical blocks (clippy::if_same_then_else)" "lint"
expect_category "pinned git-source policy requires a source" \
    '2026-11-14T02:43:44Z 01E FAIL: deny.toml: add "https://gitlab.com/vauchi/linux-gtk.git"' "lint"
expect_category "git-source policy rejects a source" \
    'FAIL: crates/app/deny.toml: remove "https://gitlab.com/vauchi/linux-qt.git"' "lint"
expect_escalate "git-source policy failure is actionable" \
    'FAIL: deny.toml: add "https://gitlab.com/vauchi/linux-gtk.git"' "false"
expect_category "matching git-source policy is not a failure" \
    "OK: deny.toml" "unknown"
expect_category "REUSE compliance failure with GitLab timestamp" \
    "2026-10-25T04:27:25.318203Z 01O Unfortunately, your project is not compliant with version 3.3 of the REUSE Specification :-(" "lint"
expect_escalate "REUSE compliance failure does NOT escalate" \
    "Unfortunately, your project is not compliant with version 3.3 of the REUSE Specification :-(" "false"
expect_category "REUSE success does not invent a failure" \
    "Congratulations! Your project is compliant with version 3.3 of the REUSE Specification :-)" "unknown"
expect_category "pure functional core regression" \
    "FAIL: pure-functional-core regression — vauchi-core state machines must own NO ambient time/rng/sleep, found: core_instant_now=3" "lint"
expect_category "vendored locale drift with GitLab timestamp" \
    "2026-10-26T12:14:00Z 01E vendor-locales: the vendored catalogue has drifted from locales." "lint"
expect_fix "vendored locale drift points to the companion update" \
    "vendor-locales: the vendored catalogue has drifted from locales." \
    "Check for the companion locale-sync MR; refresh core's vendored catalogue with scripts/vendor-locales.sh and validate it before retrying. Never skip the drift gate."
expect_category "current vendored locales do not invent a failure" \
    "vendor-locales: catalogue already current — no MR needed" "unknown"
expect_category "cargo-machete unused dependency" \
    "cargo-machete found the following unused dependencies in this directory:" "lint"
expect_category "implemented scenario without mapped coverage" \
    "1 @implemented scenario(s) with no test naming them:" "lint"
expect_category "added annotations name no scenario" \
    "2026-11-12T10:03:54Z 01O 6 added @scenario annotation(s) name no scenario:" "lint"
expect_escalate "dangling added annotations do not escalate" \
    "1 added @scenario annotation(s) name no scenario:" "false"
expect_category "valid added annotations do not invent a failure" \
    "7 added @scenario annotation(s) name a scenario" "unknown"
expect_category "zero dangling annotations do not invent a failure" \
    "0 added @scenario annotation(s) name no scenario:" "unknown"
expect_category "missing public shipment trailer" \
    "2026-11-12T04:11:21Z 01O VGT15: feat commit changes public text without a valid Shipped-in: trailer" "lint"
expect_category "Rust deprecated API error" \
    "error: use of deprecated method \`ProfileEngine::setup_duress_password\`: use setup_duress_pin_with_biometric_unlock" "lint"
expect_category "Rust deprecation warning alone is not a failure" \
    "warning: use of deprecated method \`ProfileEngine::setup_duress_password\`" "unknown"
expect_category "checksum success is not a failure" \
    "push-coverage.sh: OK" "unknown"
expect_category "zero checksum mismatches is not a failure" \
    "sha256sum: WARNING: 0 computed checksums did NOT match" "unknown"
expect_category "public scenario removal leaves dangling annotations" \
    "2026-11-12T15:15:21Z 01O 8 @scenario annotation(s) naming no scenario:" "lint"
expect_escalate "public scenario removal is a known lint failure" \
    "8 @scenario annotation(s) naming no scenario:" "false"
expect_category "zero removed-scenario annotations is not a failure" \
    "0 @scenario annotation(s) naming no scenario:" "unknown"
expect_category "grandfathered annotation summary is not a new failure" \
    "1246 @scenario annotation(s) name no scenario; 1267 in the dangling baseline" "unknown"
expect_category "ADR constraint violation" \
    "2026-11-12T07:29:04Z 01E adr-constraints: vauchi-core never depends on vauchi-app, not even for its tests (#1230)" "lint"
expect_category "cargo-deny reports vulnerable dependency" \
    "error[vulnerability]: TLS session values expose secrets" "dep-resolution"
expect_category "artifact gap" \
    "cp: cannot stat 'target/release/libvauchi.a': No such file or directory" "artifact-gap"
expect_category "SPM mirror handoff gap" \
    "ERROR: mirror /Users/runner/.cache/vauchi-platform-swift-mirror/v0.59.3 missing — build:debug should have built it." \
    "artifact-gap"
expect_category "corrupt Swift package cache" \
    "fatal: unable to read tree (e3eee48d41822e73a7287c94998ee3b251a3000c)" \
    "artifact-gap"
expect_category "remote scripts ref artifact gap" \
    'curl: (22) The requested URL returned error: 404' "artifact-gap"
expect_category "duplicate package publish" \
    'curl: (22) The requested URL returned error: 400' "duplicate-publish"
expect_escalate "duplicate package publish does NOT escalate" \
    'curl: (22) The requested URL returned error: 400' "false"
expect_fix "duplicate package publish forbids registry deletion" \
    'curl: (22) The requested URL returned error: 400' \
    "Registry rejected the upload — usually a rerun at an already-published version (triggered/scheduled pipeline missing a source guard). Exclude that source from the publish job; never delete the published package to let a rerun pass."
expect_category "CI secret file decoded as inline data" \
    'base64: truncated input' "secret-decoding"
expect_escalate "CI secret decode failure does NOT escalate" \
    'base64: truncated input' "false"
expect_fix "CI secret decode failure preserves file-variable semantics" \
    'base64: truncated input' \
    "Treat GitLab file variables as paths and decode the referenced file; never pipe the path string into base64."
expect_category "semver API compatibility" \
    '--- failure method_parameter_count_changed: pub method parameter count changed ---' \
    "semver-api-compatibility"
expect_escalate "semver API compatibility does NOT escalate" \
    'Summary semver requires new major version: 1 major and 0 minor checks failed' \
    "false"
expect_fix "semver API compatibility preserves the gate" \
    'Summary semver requires new major version: 1 major and 0 minor checks failed' \
    "Restore the public API compatibility or intentionally bump the major version; never suppress the semver lint."
expect_category "YAML syntax" \
    "yaml.scanner.ScannerError: could not find expected ':'" \
    "yaml-syntax"
expect_escalate "YAML syntax does NOT escalate" \
    "could not find expected ':'" "false"
expect_fix "YAML syntax preserves the lint gate" \
    "could not find expected ':'" \
    "Fix the invalid YAML indentation or syntax, then rerun the CI lint; never suppress the lint."
expect_category "required CI template variable" \
    "/usr/bin/bash: line 222: FETCH_SCRIPT_PATH: FETCH_SCRIPT_PATH must be set" \
    "template-contract"
expect_category "parser path moved during extraction" \
    "ERROR: PARSER_FILE not found: src/ui/presentation_renderer" \
    "template-contract"
expect_escalate "missing parser path does NOT escalate" \
    "ERROR: PARSER_FILE not found: src/ui/presentation_renderer" "false"
expect_fix "missing parser path names the consumer variable" \
    "ERROR: PARSER_FILE not found: src/ui/presentation_renderer" \
    "Point PARSER_FILE at the consuming shell's current parser path; preserve the parity check after moving files."
expect_escalate "required CI template variable does NOT escalate" \
    "FETCH_SCRIPT_PATH: FETCH_SCRIPT_PATH must be set" "false"
expect_fix "required CI template variable preserves execution order" \
    "FETCH_SCRIPT_PATH: FETCH_SCRIPT_PATH must be set" \
    "Bind the required CI-template variable before the shared step; flatten nested !reference chains if ordering was lost."
expect_category "minimum just syntax compatibility" \
    "error: Recipe \`create\` has both shebang line and \`[script]\` attribute" \
    "just-syntax"
expect_escalate "minimum just syntax compatibility does NOT escalate" \
    "has both shebang line and \`[script]\` attribute" "false"
expect_fix "minimum just syntax chooses one interpreter contract" \
    "has both shebang line and \`[script]\` attribute" \
    "Use a shebang recipe or the [script] attribute, not both; verify with the minimum supported just version."

expect_category "runner image missing" \
    "ERROR: Job failed (system failure): Error response from daemon: no such image: registry.example/alpine@sha256:abc (image.go:116:0s)" \
    "runner-infrastructure"
expect_category "runner image proxy returned HTTP 404" \
    'failed to pull image "registry.example/dependency_proxy/containers/alpine:3.21": error parsing HTTP 404 response body' \
    "runner-infrastructure"
expect_category "runner image pull deadline" \
    'failed to pull image "registry.example/dependency_proxy/containers/node:20": context deadline exceeded' \
    "runner-infrastructure"
expect_category "Gradle JDK image transform incompatibility" \
    "> Execution failed for JdkImageTransform: /opt/android-sdk/platforms/android-35/core-for-system-modules.jar." \
    "toolchain-compatibility"
expect_category "local filesystem permission failure" \
    "error: failed to write dependencies to '/builds/vauchi/core/target/debug/deps/foo.d': Permission denied (os error 13)" \
    "filesystem-permission"
expect_category "external Vaultwarden contract drift" \
    "ERROR: Vaultwarden item 'Deployment Identity' does not contain the Infisical machine identity" \
    "external-config-drift"
expect_category "Vaultwarden item absent after sync" \
    "ERROR: Vaultwarden item 'Infisical Waitlist Deployer' not found" \
    "external-config-drift"
expect_category "duplicate Vaultwarden item name" \
    "ERROR: Vaultwarden item name 'Infisical Waitlist Deployer' is ambiguous: 2 exact matches" \
    "external-config-drift"
expect_category "Vaultwarden item search command failed" \
    "ERROR: Vaultwarden item search failed" \
    "external-config-drift"
expect_category "Vaultwarden identity fields missing" \
    "ERROR: could not extract INFISICAL_CLIENT_ID from Vaultwarden item 'Deployment Identity'" \
    "external-config-drift"
expect_category "Vaultwarden custom field missing" \
    "ERROR: Vaultwarden item 'Cloudflare R2 Object Store' has no RESTIC_PASSWORD custom field" \
    "external-config-drift"
expect_category "Vaultwarden bootstrap field missing" \
    "ERROR: 'Infisical Master Keys' has neither a KEY custom field nor a KEY= notes line" \
    "external-config-drift"
expect_category "C# compiler diagnostic" \
    "ViewModel.cs(37,18): error CS0103: The name 'EqualityComparer' does not exist in the current context" \
    "compile-error"
expect_category "Gradle test failure summary" \
    "146 tests completed, 73 failed" "test-failure"
expect_category "mutation survivors" \
    "139 mutants tested in 4m: 51 missed, 56 caught, 32 unviable" "test-failure"
expect_category "Python unittest assertion failure" \
    "2026-11-25T08:36:15Z 01E FAILED (failures=1, skipped=4, expected failures=7)" "test-failure"
expect_category "Python unittest error" \
    "FAILED (errors=2)" "test-failure"
expect_category "zero Python unittest failures are not a failure signature" \
    "FAILED (failures=0)" "unknown"
expect_category "empty e2e test listing fails its coverage gate" \
    "ERROR: no vauchi-e2e-tests::it test was listed; does the crate build?" "test-failure"
expect_category "generic self-test suite failure" \
    "FAILED: 1 self-test suite(s) red." "test-failure"
expect_category "connection reset by peer" \
    "urllib.error.URLError: <urlopen error [Errno 54] Connection reset by peer>" \
    "transient-network"
for gateway_status in 502 503 504; do
    expect_category "curl gateway failure $gateway_status" \
        "curl: (22) The requested URL returned error: $gateway_status" \
        "transient-network"
    expect_escalate "curl gateway failure $gateway_status does NOT escalate" \
        "curl: (22) The requested URL returned error: $gateway_status" "false"
done
expect_category "HTTP status boundary is exact" \
    "curl: (22) The requested URL returned error: 5040" "unknown"
expect_category "unrelated numeric output is not a curl gateway failure" \
    "Processed 504 records successfully" "unknown"
expect_category "release package is not consumable" \
    "Release v0.59.2 is tagged but not consumable: spm" "artifact-gap"
expect_category "downstream trigger authorization" \
    "curl: (22) The requested URL returned error: 403" "authorization"
expect_category_with_failure_reason "runner system failure metadata fallback" \
    "ERROR: Job failed" "runner_system_failure" "runner-infrastructure"
expect_category_with_failure_reason "runner configuration metadata fallback" \
    "ERROR: Job failed" "runner_configuration_error" "runner-infrastructure"
expect_category_with_failure_reason "job timeout metadata fallback" \
    "ERROR: Job failed" "job_execution_timeout" "timeout"
expect_category_with_failure_reason "specific trace beats generic runner metadata" \
    "error[E0433]: failed to resolve: use of undeclared crate" \
    "runner_system_failure" "compile-error"

expect_category "immutable template pin mismatch" \
    "FAIL: shared template ref is 1e039df4a5488fdca44d7254cec79157dc408edf" "test-failure"
expect_category "immutable runtime pin mismatch" \
    "FAIL: runtime scripts ref is 1e039df4a5488fdca44d7254cec79157dc408edf" "test-failure"

expect_category "cucumber wired scenario coverage regression" \
    "cucumber GATE failed: 134 wired scenario(s) passed, expected at least 135" "test-failure"

expect_category "CMake pkg-config camera SDK missing" \
    "-- Package 'libpipewire-0.3', required by 'virtual:world', not found" "missing-tool"
expect_category "native SDK absence beats a Rust build script panic" \
    "thread 'main' panicked at libspa-sys/build.rs:10:
The system library 'libpipewire-0.3' required by crate 'libspa-sys' was not found." "missing-tool"
expect_escalate "missing native SDK does not escalate" \
    "Package 'libpipewire-0.3', required by 'virtual:world', not found" "false"
expect_category "successful pkg-config discovery is not a missing SDK" \
    "-- Found libpipewire-0.3, version 1.4.2" "unknown"
expect_category "broken pkg-config backend still needs investigation" \
    "pkg-config crashed with signal 11" "unknown"
expect_category "runner cannot prompt for sudo credentials" \
    "sudo: a terminal is required to read the password; either use the -S option to read from standard input or configure an askpass helper" "authorization"
expect_category "runner needs a sudo password" \
    "sudo: a password is required" "authorization"
expect_category "unrelated sudo backend error is not a credential verdict" \
    "sudo: unable to resolve host runner" "unknown"

# Unknown → escalate to the model
expect_category "unknown signature" \
    "some totally novel error nobody has a rule for yet" "unknown"
expect_escalate "unknown escalates"   "novel unseen failure text" "true"
expect_escalate "known does NOT escalate" \
    "error: failed to select a version for \`libc\`" "false"

# Specificity: a compile error line that also contains the word "failed"
# must classify as compile-error, not test-failure (order matters).
expect_category "compile-error beats generic failed" \
    "error[E0599]: no method named foo; note: build failed" "compile-error"

echo ""
if [[ "$FAIL" -eq 0 ]]; then
    printf 'classify-ci-failure.test: %d passed, 0 failed\n' "$PASS"; exit 0
else
    printf 'classify-ci-failure.test: %d passed, %d FAILED\n' "$PASS" "$FAIL"; exit 1
fi
