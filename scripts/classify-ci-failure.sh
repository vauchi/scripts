#!/usr/bin/env bash
# SPDX-FileCopyrightText: 2026 Mattia Egloff <mattia.egloff@pm.me>
# SPDX-License-Identifier: GPL-3.0-or-later
#
# Deterministic CI-failure classifier. Reads a GitLab job trace (stdin or
# a file argument) and prints a JSON verdict:
#
#   {"category":"c-ffi-cross","escalate":false,
#    "signature":"<first matching line>","fix":"<short hint>"}
#
# Why: `/ci-fix` and the ci-fixer agent both carry a prose signature→fix
# table and spend model tokens re-deriving it on every failure. This turns
# the common 80% into a regex lookup — the model is reserved for the actual
# fix and for the unknown tail (category "unknown", escalate=true). Same
# "classical matching instead of a model" lever as the lint hooks.
#
# Signatures are ordered MOST-SPECIFIC first; first match wins. Categories
# and fixes mirror the table in `.claude/skills/ci-fix/SKILL.md` /
# `.claude/agents/ci-fixer.md` — keep the three in sync.
#
# Usage:
#   glab api ".../jobs/<id>/trace" | scripts/scripts/classify-ci-failure.sh
#   scripts/scripts/classify-ci-failure.sh --failure-reason runner_system_failure
#   scripts/scripts/classify-ci-failure.sh trace.txt

set -euo pipefail

set -uo pipefail

FAILURE_REASON=""
if [[ "${1:-}" == "--failure-reason" ]]; then
    if [[ $# -lt 2 ]]; then
        echo "ERROR: --failure-reason requires a value" >&2
        exit 2
    fi
    FAILURE_REASON="$2"
    shift 2
fi

if [[ $# -ge 1 && -f "$1" ]]; then
    TRACE=$(cat "$1")
else
    TRACE=$(cat)
fi

# Ordered, index-aligned rule arrays (patterns contain '|', so parallel
# arrays are used instead of a delimited string).
# Order matters — a compile error line can also contain the word "failed",
# so error[E####] must be tried before the generic test-failure rule.
CATS=(
  "test-failure"
  "runner-infrastructure"
  "missing-tool"
  "authorization"
  "lint"
  "dep-resolution" "test-failure"
  "artifact-integrity"
  "runner-infrastructure" "dep-resolution"
  "just-syntax" "lint"
  "template-contract"
  "lint" "lint"
  "toolchain-compatibility"
  "semver-api-compatibility" "yaml-syntax" "just-syntax" "template-contract" "secret-decoding" "c-ffi-cross" "branch-protection" "authorization" "target-health" "runner-infrastructure" "toolchain-compatibility" "filesystem-permission" "external-config-drift" "transient-network" "timeout" "dep-resolution"
  "missing-tool" "compile-error" "lint" "lint" "test-failure" "duplicate-publish" "artifact-gap"
)
PATS=(
  "FAILED: [1-9][0-9]* self-test suite\\(s\\) red[.]"
  "No space left on device"
  "(Package '[^']+', required by '[^']+', not found|The system library .* required by crate .* was not found)"
  "sudo: (a terminal is required to read the password|a password is required|no tty present and no askpass program specified)"
  "jscpd-new-clones: duplication grew:"
  "cohort: ERROR: untrusted lockfile source"
  "ERROR: Performance regression > [0-9]+([.][0-9]+)?% detected!"
  "sha256sum: WARNING: [1-9][0-9]* computed checksums? did NOT match"
  "sccache: error: Timed out waiting for server startup"
  "FAIL: .* (pins|resolves) Core crates at another tag than (the )?set's v"
  "The .?\\[script\\].? attribute is currently unstable"
  "VSP01: pinned ci-templates-v[0-9]+\\.[0-9]+\\.[0-9]+ is not among the latest ci-template tags"
  "ERROR: PARSER_FILE not found:"
  "VGT15: .*commit changes public text without a valid Shipped-in: trailer"
  "error: use of deprecated (method|function)"
  "ModuleNotFoundError: No module named 'tomllib'"
  "(failure method_parameter_count_changed:|Summary semver requires new major version:)"
  "could not find expected ':'[[:space:]]*$"
  "has both shebang line and .*\\[script\\].* attribute"
  ":[[:space:]][A-Z][A-Z0-9_]* must be set([[:space:]]|$)"
  "base64: truncated input"
  "fatal error: '[^']+\\.h' file not found"
  "pre-receive hook declined"
  "curl: \\(22\\) The requested URL returned error: 403"
  "target failed to become healthy within configured timeout"
  "(failed to pull image|Error response from daemon: no such image:|image pull failed)"
  "(JdkImageTransform|androidJdkImage|Failed to transform core-for-system-modules\\.jar)"
  "Permission denied \(os error 13\)"
  "(Vaultwarden item( name)? .* (does not contain|not found|is ambiguous|is missing|has neither|has no)|Vaultwarden item search (failed|returned invalid data)|could not extract .* from Vaultwarden item|^ERROR: '[^']+' has neither a .* custom field)"
  "(Could not resolve host:|DNS: transient error \(try again later\)|Connection reset by peer|fatal: unable to access '[^']+': Failed to connect to [^[:space:]]+(:[0-9]+| port [0-9]+) after [0-9]+ ms: Could not connect to server|curl: \\(22\\) The requested URL returned error: (502|503|504)([[:space:]]|$))"
  "(exceeded maximum timeout|Job exceeded|execution took longer than [0-9]+[hms]|context deadline exceeded)"
  "(failed to select a version|[0-9]+ (low|moderate|high|critical) severity (vulnerability|vulnerabilities)|error: [0-9]+ (vulnerability|vulnerabilities) found!|error: [0-9]+ denied warnings? found!|error\\[(vulnerability|duplicate|unmaintained)\\]:)"
  "(command not found|: not found|xvfb-run is required in CI)"
  "(error\\[E[0-9]+\\]|error CS[0-9]{4}:|error: missing argument for parameter|No value passed for parameter|cannot find '[^']+' in scope|undefined reference to)"
  "vendor-locales: the vendored catalogue has drifted from locales\\."
  "(clippy::|^Diff in |rustfmt|MD[0-9]{3}|@implemented scenario\\(s\\) with no test naming them:|(^|[^[:digit:]])[1-9][0-9]* @scenario annotation\\(s\\) naming no scenario:|adr-constraints: |(^|[^[:digit:]])[1-9][0-9]* added @scenario annotation\\(s\\) name no scenario:|cargo-machete found the following unused dependencies|pure-functional-core regression|\\[ERROR\\] file://.*Cannot find file: File not found|not compliant with version [0-9.]+ of the REUSE Specification|FAIL: .*deny[.]toml: (add|remove) )"
  "(test result: FAILED|cucumber GATE failed:|[Aa]ssertion .*failed|panicked at|[0-9]+ tests completed, [1-9][0-9]* failed|[0-9]+ mutants tested.*[1-9][0-9]* missed|FAILED: [1-9][0-9]* (hook |runner-infrastructure )?self-test suite\(s\) red\.|(FAILED|ERROR) [^[:space:]]+[.]py::|FAIL: .* got exit [1-9][0-9]*|FAIL: (shared template ref is|runtime scripts ref is)|ValueError: expected (_private|private) git common directory|FAILED \\((failures|errors)=[1-9][0-9]*([,)]|$)|ERROR: no vauchi-e2e-tests::it test was listed; does the crate build[?])"
  "curl: \\(22\\) The requested URL returned error: 400"
  "(No such file or directory|curl: \(22\) The requested URL returned error: 404|fatal: unable to read tree|DllNotFoundException.*Unable to load DLL|ERROR: mirror .* missing .* build:debug should have built it|Release v[^ ]+ is tagged but not consumable:)"
)
FIXES=(
  "Inspect the failing self-test and repair its code or fixture; earlier expected-error fixture output is not the job failure."
  "Restore free space and inodes on the runner; remove only stale build/cache data, preserve active jobs, then retry without changing application code."
  "Install the native development packages required by pkg-config in runner setup before compiling; keep the feature and its checks enabled."
  "The runner cannot perform interactive privilege escalation. Use job-local build dependencies or a maintainer-managed runner image; never embed an account password."
  "Refactor the new duplicated source into shared helpers; rerun the pinned jscpd comparison against main without changing its allowance or baseline."
  "Compare the new dependency source with the protected Core release's lockfile; admit only release-authorized package identities and keep rejecting unrelated sources."
  "Inspect the regressing benchmark and its baseline under comparable runner load; fix the measured regression or invalid comparison without relaxing the performance gate."
  "Verify the downloaded bytes against the pinned source ref, then correct the ref or expected digest; never bypass checksum verification."
  "Inspect the sccache version and daemon startup logs; use a version with the startup notification race fixed, and preserve the cache-hit probe."
  "Select successful relay and CLI commits that pin the set's Core tag, then update the cohort pins and lockfile together; preserve the pin guard."
  "Enable JUST_UNSTABLE=1 for the CI command or pass --unstable; preserve the minimum supported just version."
  "Move the shared CI include and runtime ref to the current verified ci-templates release commit, then rerun local checks."
  "Point PARSER_FILE at the consuming shell's current parser path; preserve the parity check after moving files."
  "Recreate the unshipped text commit with a valid Shipped-in trailer naming the actual shipped work; keep dependent documentation Draft until that work merges."
  "Replace the deprecated API with its documented successor and retain the behavior assertions; do not suppress deprecation errors."
  "Use Python 3.11+ or install a pinned tomli backport and fall back to it when tomllib is unavailable."
  "Restore the public API compatibility or intentionally bump the major version; never suppress the semver lint."
  "Fix the invalid YAML indentation or syntax, then rerun the CI lint; never suppress the lint."
  "Use a shebang recipe or the [script] attribute, not both; verify with the minimum supported just version."
  "Bind the required CI-template variable before the shared step; flatten nested !reference chains if ordering was lost."
  "Treat GitLab file variables as paths and decode the referenced file; never pipe the path string into base64."
  "Feature-gate the C dep in Cargo.toml (optional=true; #[cfg(feature)]); verify: cargo check --no-default-features"
  "Not a code fix — GitLab branch-protection/push rules; check MR settings and gate-push."
  "Check the token scope, project allowlist, and protected-resource permissions; do not weaken authorization to make the request pass."
  "Inspect the proxy target address, network, port, and health path; only raise the deploy timeout when a valid target genuinely starts slowly."
  "Restore the runner image or dependency-proxy path; retry only after the runner can resolve and pull the configured image."
  "Align the build JDK and Android Gradle Plugin versions; reproduce with the repository's just build/check recipe."
  "Repair runner workspace ownership or target-directory permissions; do not run the build with elevated application permissions."
  "Restore the Vaultwarden session and one exact-name item with validated fields; remove or rename duplicates and never print secret material."
  "Runner or registry networking is unavailable; restore connectivity, then retry without changing application code."
  "Optimise the job or raise the .timeout-* template; suspect resource starvation before code."
  "Refresh the dependency constraint or lockfile so it selects a patched compatible version."
  "Install the tool in before_script (prefer cargo-binstall) or fix the runner image."
  "Read the rustc diagnostic; fix the source. Reproduce with cargo check -p <crate>."
  "Check for the companion locale-sync MR; refresh core's vendored catalogue with scripts/vendor-locales.sh and validate it before retrying. Never skip the drift gate."
  "Run the matching just check/lint locally and fix the source (never suppress — CC-21)."
  "Read the failing assertion; fix code or test. Never retry without a root-cause fix (CC-18)."
  "Registry rejected the upload — usually a rerun at an already-published version (triggered/scheduled pipeline missing a source guard). Exclude that source from the publish job; never delete the published package to let a rerun pass."
  "An artifact or source cache is unavailable or corrupt: fix the pinned ref/artifact flow, or clear the corrupt cache before retrying."
)

emit() { # category, escalate, signature, fix
  jq -nc --arg c "$1" --argjson e "$2" --arg s "$3" --arg f "$4" \
    '{category:$c, escalate:$e, signature:$s, fix:$f}'
}

for i in "${!CATS[@]}"; do
  cat="${CATS[$i]}"
  pat="${PATS[$i]}"
  fix="${FIXES[$i]}"
  line=$(printf '%s\n' "$TRACE" | grep -m1 -E "$pat" 2>/dev/null || true)
  if [[ -n "$line" ]]; then
    # Trim leading whitespace and cap length for the signature field.
    sig=$(printf '%s' "$line" | sed -E 's/^[[:space:]]+//' | head -c 200)
    emit "$cat" false "$sig" "$fix"
    exit 0
  fi
done

case "$FAILURE_REASON" in
  runner_system_failure|runner_configuration_error)
    emit "runner-infrastructure" false "$FAILURE_REASON" "Inspect the runner configuration and system logs; restore runner health before retrying without changing application code."
    exit 0
    ;;
  job_execution_timeout)
    emit "timeout" false "$FAILURE_REASON" "Optimise the job or raise the .timeout-* template; suspect resource starvation before code."
    exit 0
    ;;
esac

emit "unknown" true "" "No known signature matched — hand to the model for classification and fix."
exit 0
