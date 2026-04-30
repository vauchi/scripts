#!/bin/bash
# SPDX-FileCopyrightText: 2026 Mattia Egloff <mattia.egloff@pm.me>
# SPDX-License-Identifier: GPL-3.0-or-later
#
# gen-hook-from-pattern.sh — emit a draft PreToolUse hook from
# observed patterns in `.claude/.session-errors`.
#
# The 3-strike rule in `just session-end` flags categories that have
# logged 3+ session occurrences. When a pattern crosses that line,
# observation should escalate to blocking. This script reads the
# error ledger, picks the noisiest blockable category, and emits a
# starter hook script + a settings.json registration snippet.
#
# Output:
#   .claude/hooks/pretool-<category>.sh          (draft, executable)
#   .claude/hooks/pretool-<category>.snippet     (settings.json patch)
#
# Usage:
#   just gen-hook-from-pattern               # auto-pick top category
#   just gen-hook-from-pattern <category>    # explicit category
#
# The generated hook is a STARTER. Always review thresholds, escape
# hatches, and the block message before merging — defaults are
# conservative but each pattern needs its own escape logic.

set -uo pipefail

WORKSPACE_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
LEDGER="$WORKSPACE_ROOT/_private/docs/reference/error-ledger.jsonl"
SESSION_ERRORS="$WORKSPACE_ROOT/.claude/.session-errors"
HOOKS_DIR="$WORKSPACE_ROOT/.claude/hooks"

if [[ ! -f "$LEDGER" && ! -f "$SESSION_ERRORS" ]]; then
    echo "no ledger or session log found — nothing to learn from" >&2
    exit 1
fi

# Pick the category to escalate. Sources: the persistent ledger plus
# the current session's log. Prefer explicit argument.
CATEGORY="${1:-}"
if [[ -z "$CATEGORY" ]]; then
    # jq parsing is tolerant of bad JSON via `fromjson?` — silently skips
    # lines that don't parse (the ledger has historical control-char bugs).
    CATEGORY=$( {
        [[ -f "$LEDGER" ]] && cat "$LEDGER" || true
        [[ -f "$SESSION_ERRORS" ]] && cat "$SESSION_ERRORS" || true
    } 2>/dev/null \
        | jq -Rr 'fromjson? | select(.category != null) | .category' 2>/dev/null \
        | sort \
        | uniq -c \
        | sort -rn \
        | head -1 \
        | awk '{print $2}')
fi

if [[ -z "$CATEGORY" ]]; then
    echo "no category found in ledger" >&2
    exit 1
fi

OCCURRENCES=$( {
    [[ -f "$LEDGER" ]] && cat "$LEDGER" || true
    [[ -f "$SESSION_ERRORS" ]] && cat "$SESSION_ERRORS" || true
} 2>/dev/null \
    | grep -cF "\"category\":\"$CATEGORY\"" \
    | tr -d ' ')

echo "Top blockable category: $CATEGORY ($OCCURRENCES occurrences)"

# Map category → tool matcher and concrete hook body. New categories
# just need a case branch added below; the generator handles plumbing.
HOOK_NAME="pretool-${CATEGORY}.sh"
HOOK_PATH="$HOOKS_DIR/$HOOK_NAME"
SNIPPET_PATH="$HOOKS_DIR/pretool-${CATEGORY}.snippet"

case "$CATEGORY" in
    excessive-reread)
        MATCHER="Read"
        THRESHOLD=3
        BODY=$(cat <<'BODY'
INPUT=$(cat)
FILE_PATH=$(echo "$INPUT" | jq -r '.tool_input.file_path // empty')
OFFSET=$(echo "$INPUT" | jq -r '.tool_input.offset // empty')
LIMIT=$(echo "$INPUT" | jq -r '.tool_input.limit // empty')
[[ -z "$FILE_PATH" ]] && exit 0
# Region-targeted reads bypass the cap — they're not redundant.
[[ -n "$OFFSET" || -n "$LIMIT" ]] && exit 0

TRACKER="${CLAUDE_PROJECT_DIR:-.}/.claude/.session-reads"
COUNT=$([[ -f "$TRACKER" ]] && grep -cF "$FILE_PATH" "$TRACKER" 2>/dev/null || echo "0")

# Verify-after-edit escape: if there's been an Edit/Write since the
# last Read of this file, allow.
EDITS_TRACKER="${CLAUDE_PROJECT_DIR:-.}/.claude/.session-edits"
if [[ -f "$EDITS_TRACKER" && "$COUNT" -ge 3 ]]; then
    LAST_READ=$(grep -nF "$FILE_PATH" "$TRACKER" 2>/dev/null | tail -1 | cut -d: -f1)
    LAST_EDIT=$(grep -nF "$FILE_PATH" "$EDITS_TRACKER" 2>/dev/null | tail -1 | cut -d: -f1)
    [[ -n "$LAST_EDIT" && -n "$LAST_READ" && "$LAST_EDIT" -gt "$LAST_READ" ]] && exit 0
fi

if [[ "$COUNT" -ge 3 ]]; then
    echo "Blocked: $((COUNT + 1))th Read of $FILE_PATH this session." >&2
    echo "Use Grep, sed -n, or trust your context." >&2
    exit 2
fi
BODY
)
        ;;
    excessive-reedit)
        MATCHER="Edit"
        THRESHOLD=4
        BODY=$(cat <<'BODY'
INPUT=$(cat)
TOOL=$(echo "$INPUT" | jq -r '.tool_name // empty')
[[ "$TOOL" != "Edit" ]] && exit 0
FILE_PATH=$(echo "$INPUT" | jq -r '.tool_input.file_path // empty')
[[ -z "$FILE_PATH" ]] && exit 0

TRACKER="${CLAUDE_PROJECT_DIR:-.}/.claude/.session-edits"
COUNT=$([[ -f "$TRACKER" ]] && grep -cF "$FILE_PATH" "$TRACKER" 2>/dev/null || echo "0")
if [[ "$COUNT" -ge 4 ]]; then
    echo "Blocked: $((COUNT + 1))th Edit of $FILE_PATH this session." >&2
    echo "Use Write to replace the whole file, or batch the remaining" >&2
    echo "changes into a single Edit with replace_all." >&2
    exit 2
fi
BODY
)
        ;;
    *)
        echo "no generator template for category '$CATEGORY' — add a case branch" >&2
        echo "to gen-hook-from-pattern.sh with the matcher and block body." >&2
        exit 1
        ;;
esac

# Don't overwrite an existing hook unless the user passes --force.
if [[ -f "$HOOK_PATH" && "${2:-}" != "--force" ]]; then
    echo "$HOOK_PATH already exists. Pass --force as the 2nd arg to overwrite." >&2
    exit 1
fi

cat > "$HOOK_PATH" <<EOF
#!/bin/bash
# SPDX-FileCopyrightText: 2026 Mattia Egloff <mattia.egloff@pm.me>
# SPDX-License-Identifier: GPL-3.0-or-later
#
# Auto-generated by scripts/gen-hook-from-pattern.sh.
# Source pattern: $CATEGORY ($OCCURRENCES observed occurrences).
# Threshold: $THRESHOLD.
#
# REVIEW BEFORE MERGE. Tune the threshold and escape hatches for the
# specific pattern. The default block message is generic; replace
# with concrete guidance on what to do instead.

$BODY
EOF

chmod +x "$HOOK_PATH"

cat > "$SNIPPET_PATH" <<EOF
# Add to .claude/settings.json under hooks.PreToolUse:
{
  "matcher": "$MATCHER",
  "hooks": [
    {
      "type": "command",
      "command": "\$CLAUDE_PROJECT_DIR/.claude/hooks/$HOOK_NAME",
      "timeout": 5
    }
  ]
}
EOF

echo "Generated:"
echo "  $HOOK_PATH"
echo "  $SNIPPET_PATH"
echo
echo "Next steps:"
echo "  1. Review the threshold ($THRESHOLD) and block message."
echo "  2. Add the snippet to .claude/settings.json under hooks.PreToolUse."
echo "  3. Test in a fresh session — verify legitimate use isn't blocked."
echo "  4. Commit with 'feat: PreToolUse $CATEGORY hook (3-strike escalation)'."
