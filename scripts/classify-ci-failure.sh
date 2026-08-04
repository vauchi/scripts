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
#   scripts/scripts/classify-ci-failure.sh trace.txt

set -euo pipefail

set -uo pipefail

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
  "semver-api-compatibility" "yaml-syntax" "just-syntax" "template-contract" "secret-decoding" "c-ffi-cross" "branch-protection" "target-health" "timeout" "dep-resolution"
  "missing-tool" "compile-error" "lint" "test-failure" "duplicate-publish" "artifact-gap"
)
PATS=(
  "(failure method_parameter_count_changed:|Summary semver requires new major version:)"
  "could not find expected ':'[[:space:]]*$"
  "has both shebang line and .*\\[script\\].* attribute"
  ":[[:space:]][A-Z][A-Z0-9_]* must be set([[:space:]]|$)"
  "base64: truncated input"
  "fatal error: '[^']+\\.h' file not found"
  "pre-receive hook declined"
  "target failed to become healthy within configured timeout"
  "(exceeded maximum timeout|Job exceeded|execution took longer than [0-9]+[hms])"
  "(failed to select a version|[0-9]+ (low|moderate|high|critical) severity (vulnerability|vulnerabilities))"
  "(command not found|: not found)"
  "(error\\[E[0-9]+\\]|error: missing argument for parameter|No value passed for parameter|cannot find '[^']+' in scope|undefined reference to)"
  "(clippy::|^Diff in |rustfmt|MD[0-9]{3})"
  "(test result: FAILED|assertion .*failed|panicked at|FAILED: [0-9]+ hook self-test suite\(s\) red\.|ValueError: expected (_private|private) git common directory)"
  "curl: \\(22\\) The requested URL returned error: 400"
  "(No such file or directory|curl: \(22\) The requested URL returned error: 404|fatal: unable to read tree|DllNotFoundException.*Unable to load DLL)"
)
FIXES=(
  "Restore the public API compatibility or intentionally bump the major version; never suppress the semver lint."
  "Fix the invalid YAML indentation or syntax, then rerun the CI lint; never suppress the lint."
  "Use a shebang recipe or the [script] attribute, not both; verify with the minimum supported just version."
  "Bind the required CI-template variable before the shared step; flatten nested !reference chains if ordering was lost."
  "Treat GitLab file variables as paths and decode the referenced file; never pipe the path string into base64."
  "Feature-gate the C dep in Cargo.toml (optional=true; #[cfg(feature)]); verify: cargo check --no-default-features"
  "Not a code fix — GitLab branch-protection/push rules; check MR settings and gate-push."
  "Inspect the proxy target address, network, port, and health path; only raise the deploy timeout when a valid target genuinely starts slowly."
  "Optimise the job or raise the .timeout-* template; suspect resource starvation before code."
  "Refresh the dependency constraint or lockfile so it selects a patched compatible version."
  "Install the tool in before_script (prefer cargo-binstall) or fix the runner image."
  "Read the rustc diagnostic; fix the source. Reproduce with cargo check -p <crate>."
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

emit "unknown" true "" "No known signature matched — hand to the model for classification and fix."
exit 0
