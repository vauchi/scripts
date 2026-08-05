#!/usr/bin/env bash
# SPDX-FileCopyrightText: 2026 Mattia Egloff <mattia.egloff@pm.me>
#
# SPDX-License-Identifier: GPL-3.0-or-later

# check-no-allow-direct.sh — Forbid production direct-transport opt-ins and
# retired `VAUCHI_ALLOW_DIRECT=1` outside an approved allow-list.
#
# Usage: check-no-allow-direct.sh <repo_root> [<repo_root> ...]
# Example: check-no-allow-direct.sh core cli tui e2e
#
# Background: `HttpTransportConfig::allow_direct` controls whether the HTTP
# transport falls back to direct (non-OHTTP) HTTP when no OHTTP gateway key
# is wired. Setting it to `true` exposes the caller's source IP to the relay
# and defeats ADR-037's IP-privacy property.
#
# The 2026-04-17 audit (finding A1) found 8 production call sites overriding
# the default. After remediation the remaining legitimate uses are:
#
#   1. Test helpers — `HttpTransportConfig::for_testing(...)` and any
#      occurrence inside `#[cfg(test)]`, `#[cfg(feature = "testing")]`,
#      `#[cfg(debug_assertions)]`, `#[test]`, or a `mod tests { ... }` block.
#   2. The bootstrap path in `core/vauchi-core/src/api/vauchi/sync_http.rs`
#      (`create_bootstrap_transport_direct`) targets the distinct outer OHTTP
#      relay, never the application relay. It fetches only public bootstrap
#      material and carries no application-user identifier.
#
# Any OTHER occurrence is a privacy regression and this script exits non-zero.

set -euo pipefail

if [ $# -lt 1 ]; then
    echo "Usage: $0 <repo_root> [<repo_root> ...]"
    echo "Example: $0 core cli tui e2e"
    exit 2
fi

VIOLATIONS=0
REPORTED=""

for ROOT in "$@"; do
    if [ ! -d "$ROOT" ]; then
        echo "Warning: $ROOT is not a directory, skipping" >&2
        continue
    fi

    # A production config is safe only when allow_direct is the literal false.
    # Reject dynamic expressions, shorthand field initializers, and calls to
    # the test-only constructor. Boolean field declarations and comparisons
    # are not initializers, so the pattern excludes them.
    HITS=$(rg --no-messages --with-filename --line-number --no-heading \
        --type rust --pcre2 \
        '(allow_direct\s*:(?!\s*bool\b)(?!\s*false\s*([,}]|//|$)))|(allow_direct\s*=(?!=)(?!\s*false\s*(;|//|$)))|((^|[{,])\s*allow_direct\s*[,}])|(HttpTransportConfig::for_testing\s*\()' \
        "$ROOT" 2>/dev/null || true)

    while IFS= read -r HIT; do
        [ -z "$HIT" ] && continue
        FILE=$(echo "$HIT" | awk -F: '{print $1}')
        LINE=$(echo "$HIT" | awk -F: '{print $2}')

        case "$FILE" in
            */tests/*|*/tests.rs|*.test.rs)
                continue
                ;;
        esac

        # Extract the file content of the matching line without the
        # "file:line:" prefix that rg prepends.
        CONTENT=$(sed -n "${LINE}p" "$FILE")

        # (1) Skip pure-comment lines (optional leading ws, then //).
        if echo "$CONTENT" | grep -Eq '^[[:space:]]*//'; then
            continue
        fi

        # (2) Skip if a `//` line-comment marker appears before the match
        # on the same line (trailing comment containing the pattern).
        AD_POS=$(echo "$CONTENT" | awk '{ print index($0, "allow_direct") }')
        SL_POS=$(echo "$CONTENT" | awk '{ print index($0, "//") }')
        if [ "$SL_POS" -gt 0 ] && [ "$SL_POS" -lt "$AD_POS" ]; then
            continue
        fi

        # (3) File-specific production exceptions.
        case "$FILE" in
            */vauchi-core/src/api/vauchi/sync_http.rs)
                START=$((LINE > 40 ? LINE - 40 : 1))
                CONTEXT=$(sed -n "${START},${LINE}p" "$FILE")
                if echo "$CONTENT" | grep -qE \
                    'allow_direct[[:space:]]*:[[:space:]]*true' \
                    && echo "$CONTEXT" | grep -q \
                        'fn create_bootstrap_transport_direct'; then
                    continue
                fi
                ;;
            */vauchi-core/src/network/http_transport.rs)
                START=$((LINE > 20 ? LINE - 20 : 1))
                CONTEXT=$(sed -n "${START},${LINE}p" "$FILE")
                if echo "$CONTENT" | grep -qE \
                    'allow_direct[[:space:]]*:[[:space:]]*true' \
                    && echo "$CONTEXT" | grep -q 'pub fn for_testing'; then
                    continue
                fi
                ;;
        esac

        # (4) Test/debug-context heuristic, scope-aware. Look 60 lines
        # back for a cfg attribute or a `mod tests { ... }` opening that
        # would scope this match to non-production code — then require
        # that sentinel's block to still be OPEN at the match.
        #
        # Distance alone is not enough. A `#[cfg(feature = "testing")]`
        # hatch that opens and closes a block does not cover the
        # production code after it. Treating it as if it did left this
        # guard blind at `Vauchi::build_relay_transport`, 17 lines below
        # its hatch and the exact site of the 2026-07-15 P0 it exists to
        # catch (problem record
        # 2026-08-05-allow-direct-guard-testing-cfg-blind-spot).
        #
        # Brace depth is tracked from the sentinel forward: once it has
        # opened and returned to zero, the sentinel is out of scope. A
        # sentinel that never opens a block (a bare attribute on a `use`
        # or a single statement) still exempts what follows, which stays
        # deliberately permissive — false negatives remain safer than
        # false positives here, since production call sites are
        # enumerated explicitly in step (3).
        START=$((LINE > 60 ? LINE - 60 : 1))
        if sed -n "${START},${LINE}p" "$FILE" | awk '
            { line[NR] = $0 }
            END {
                for (i = 1; i < NR; i++) {
                    if (line[i] !~ /debug_assertions/ &&
                        line[i] !~ /#\[test\]/ &&
                        line[i] !~ /#\[cfg\(test\)\]/ &&
                        line[i] !~ /#\[cfg\(any\(test/ &&
                        line[i] !~ /feature[ \t]*=[ \t]*"testing"/ &&
                        line[i] !~ /^[ \t]*mod[ \t]+tests[ \t]*\{/) {
                        continue
                    }
                    depth = 0
                    opened = 0
                    in_scope = 1
                    for (j = i; j < NR; j++) {
                        text = line[j]
                        depth += gsub(/\{/, "{", text)
                        depth -= gsub(/\}/, "}", text)
                        if (depth > 0) { opened = 1 }
                        if (opened && depth <= 0) { in_scope = 0; break }
                    }
                    if (in_scope) { exit 0 }
                }
                exit 1
            }
        '; then
            continue
        fi

        # Unapproved hit.
        REPORTED="$REPORTED
  $FILE:$LINE  $CONTENT"
        VIOLATIONS=$((VIOLATIONS + 1))
    done <<< "$HITS"

    # The retired CLI environment hatch is as dangerous as setting the
    # transport field directly. Detect Rust command/map injection and shell
    # assignment. Explicit `env_remove` calls do not match these patterns.
    ENV_HITS=$(
        rg --no-messages --with-filename --line-number --no-heading \
            --type rust \
            '"VAUCHI_ALLOW_DIRECT"[^,]*,[[:space:]]*"1"' \
            "$ROOT" 2>/dev/null || true
        rg --no-messages --with-filename --line-number --no-heading \
            --glob '*.sh' --glob '*.bash' --glob '*.yml' --glob '*.yaml' \
            "VAUCHI_ALLOW_DIRECT[[:space:]]*=[[:space:]]*['\"]?1['\"]?" \
            "$ROOT" 2>/dev/null || true
    )

    while IFS= read -r HIT; do
        [ -z "$HIT" ] && continue
        FILE=$(echo "$HIT" | awk -F: '{print $1}')
        LINE=$(echo "$HIT" | awk -F: '{print $2}')
        CONTENT=$(sed -n "${LINE}p" "$FILE")

        case "$FILE" in
            */tests/*|*/tests.rs|*.test.rs|*.test.sh)
                continue
                ;;
        esac

        if echo "$CONTENT" | grep -Eq '^[[:space:]]*(//|#)'; then
            continue
        fi

        REPORTED="$REPORTED
  $FILE:$LINE  $CONTENT"
        VIOLATIONS=$((VIOLATIONS + 1))
    done <<< "$ENV_HITS"
done

if [ "$VIOLATIONS" -gt 0 ]; then
    cat >&2 <<EOF
check-no-allow-direct: found $VIOLATIONS disallowed direct-transport bypass site(s):
$REPORTED

Every production allow_direct value other than literal false, every production
HttpTransportConfig::for_testing call, and every VAUCHI_ALLOW_DIRECT=1 is a
privacy regression (ADR-037): it lets HttpTransport fall back to direct HTTP
and expose the caller's source IP to the relay.

To silence a NEW legitimate use:
  1. Gate the call inside #[cfg(test)], #[cfg(feature = "testing")],
     or #[cfg(debug_assertions)] — OR
  2. Put HttpTransportConfig::for_testing(...) in a test-only path — OR
  3. Add a file-specific entry to this script's allow-list (only after
     updating the threat-model addendum and obtaining review).

See problem record
_private/docs/problems/2026-04-17-ohttp-allow-direct-fallback/
for the full rationale.
EOF
    exit 1
fi

echo "check-no-allow-direct: OK ($# repo(s) scanned, no disallowed sites)"
