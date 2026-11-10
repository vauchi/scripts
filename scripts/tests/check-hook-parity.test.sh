#!/usr/bin/env bash
# SPDX-FileCopyrightText: 2026 Mattia Egloff <mattia.egloff@pm.me>
# SPDX-License-Identifier: GPL-3.0-or-later

# Test runner for the cross-agent hook routing validator.

set -uo pipefail

DIR="$(cd "$(dirname "$0")/.." && pwd)"
SCRIPT="$DIR/check-hook-parity.sh"
WORK="/tmp/hook-parity.test.$$"

PASS=0
FAIL=0
trap 'rm -rf "$WORK"' EXIT

# Write a fixture user config registering exactly the named dispatch modes.
kimi_user_config() {
    mkdir -p "$KIMI_HOME_FIXTURE"
    : > "$KIMI_HOME_FIXTURE/config.toml"
    local mode
    for mode in "$@"; do
        printf '[[hooks]]\ncommand = %s.kimi-code/hooks/adapter.sh" %s%s\n\n' \
            '"/bin/bash "$R/' "$mode" ';' >> "$KIMI_HOME_FIXTURE/config.toml"
    done
}

# Always isolated from the operator's real ~/.kimi-code.
parity() {
    KIMI_CODE_HOME="$KIMI_HOME_FIXTURE" bash "$SCRIPT" "$@"
}

ck() {
    if [[ "$2" == "0" ]]; then
        printf '  PASS  %s\n' "$1"
        PASS=$((PASS + 1))
    else
        printf '  FAIL  %s\n' "$1"
        FAIL=$((FAIL + 1))
    fi
}

# Kimi reads only ~/.kimi-code/config.toml, so the checker consults a path
# outside the repo. Every invocation below pins KIMI_CODE_HOME at a fixture:
# without it the result depends on whichever config the operator happens to
# have, which is how this suite silently passed on one machine and failed on
# another. Nothing here may read the real user config.
KIMI_HOME_FIXTURE="$WORK/kimi-home"

fixture() {
    rm -rf "$WORK"
    mkdir -p "$WORK/.claude/hooks" "$WORK/.codex/hooks" "$WORK/.kimi-code/hooks" \
             "$KIMI_HOME_FIXTURE"
    # A real dispatch table: the checker derives the expected mode list from
    # this case statement, so a bare stub leaves it with nothing to compare.
    cat > "$WORK/.claude/hooks/agent-adapter.sh" <<'ADAPTER'
#!/bin/bash
case "$MODE" in
  pre-bash)
    :
    ;;
  post-bash)
    :
    ;;
esac
ADAPTER
    kimi_user_config pre-bash post-bash
    printf 'exec "$PROJECT_DIR/.claude/hooks/agent-adapter.sh" codex "$MODE"\n' \
        > "$WORK/.codex/hooks/adapter.sh"
    printf 'bash "$PROJECT_DIR/.claude/hooks/agent-adapter.sh" kimi "$MODE"\n' \
        > "$WORK/.kimi-code/hooks/adapter.sh"
    printf 'command = "bash .kimi-code/hooks/adapter.sh pre-bash"\n' \
        > "$WORK/.kimi-code/config.toml"
    printf 'command = "/bin/bash .codex/hooks/adapter.sh pre-bash"\ncommand = "/bin/bash .codex/hooks/adapter.sh post-bash"\n' \
        > "$WORK/.codex/config.toml"
}

# The real ~/.kimi-code/config.toml quotes the adapter path inside a TOML
# basic string, so the quote before the mode is escaped: adapter.sh\" pre-bash.
kimi_user_config_escaped() {
    mkdir -p "$KIMI_HOME_FIXTURE"
    : > "$KIMI_HOME_FIXTURE/config.toml"
    local mode
    for mode in "$@"; do
        printf '[[hooks]]\ncommand = "R=$(git rev-parse --show-toplevel); [ -f \\"$R/.kimi-code/hooks/adapter.sh\\" ] && /bin/bash \\"$R/.kimi-code/hooks/adapter.sh\\" %s || true"\n\n' \
            "$mode" >> "$KIMI_HOME_FIXTURE/config.toml"
    done
}

fixture
out=$(parity --strict "$WORK"); code=$?
ck "canonical routing exits 0" "$([[ $code -eq 0 ]] && echo 0 || echo 1)"
ck "canonical routing is reported" "$(grep -q 'canonical shared hooks' <<< "$out" && echo 0 || echo 1)"

rm "$WORK/.codex/hooks/adapter.sh"
parity --strict "$WORK" >/dev/null 2>&1; code=$?
ck "missing Codex adapter fails strict mode" "$([[ $code -eq 1 ]] && echo 0 || echo 1)"

fixture
printf '#!/bin/bash\n' > "$WORK/.kimi-code/hooks/legacy-copy.sh"
parity --strict "$WORK" >/dev/null 2>&1; code=$?
ck "legacy Kimi hook copy fails strict mode" "$([[ $code -eq 1 ]] && echo 0 || echo 1)"

fixture
printf 'command = "bash .kimi-code/hooks/legacy-copy.sh"\n' >> "$WORK/.kimi-code/config.toml"
parity --strict "$WORK" >/dev/null 2>&1; code=$?
ck "direct Kimi hook routing fails strict mode" "$([[ $code -eq 1 ]] && echo 0 || echo 1)"

fixture
kimi_user_config pre-bash          # post-bash missing
parity --strict "$WORK" >/dev/null 2>&1; code=$?
ck "partially wired Kimi user config fails strict mode" "$([[ $code -eq 1 ]] && echo 0 || echo 1)"

fixture
: > "$KIMI_HOME_FIXTURE/config.toml"
parity --strict "$WORK" >/dev/null 2>&1; code=$?
ck "unwired Kimi user config fails strict mode" "$([[ $code -eq 1 ]] && echo 0 || echo 1)"

fixture
rm -rf "$KIMI_HOME_FIXTURE"
out=$(parity --strict "$WORK"); code=$?
ck "absent Kimi user config is a note, not drift" "$([[ $code -eq 0 ]] && echo 0 || echo 1)"
ck "absent Kimi user config says so" "$(grep -q 'wiring unverified' <<< "$out" && echo 0 || echo 1)"

# 2026-11-10: the real config registered all eight modes and the check still
# reported every one missing, because its pattern expected an unescaped quote.
fixture
kimi_user_config_escaped pre-bash post-bash
out=$(parity --strict "$WORK"); code=$?
ck "Kimi user config with TOML-escaped quotes passes" "$([[ $code -eq 0 ]] && echo 0 || echo 1)"

fixture
printf 'command = "/bin/bash .codex/hooks/adapter.sh pre-bash"\n' > "$WORK/.codex/config.toml"
out=$(parity --strict "$WORK"); code=$?
ck "Codex config missing an adapter mode fails strict mode" "$([[ $code -eq 1 ]] && echo 0 || echo 1)"
ck "the missing Codex mode is named" "$(grep -q 'codex/config.toml does not register: post-bash' <<< "$out" && echo 0 || echo 1)"

# Codex has no Read tool event, so the read modes cannot be registered there.
fixture
cat >> "$WORK/.claude/hooks/agent-adapter.sh" <<'ADAPTER'
case "$MODE" in
  pre-read)
    :
    ;;
esac
ADAPTER
kimi_user_config pre-bash post-bash pre-read
out=$(parity --strict "$WORK"); code=$?
ck "Codex is not asked to register the read modes" "$([[ $code -eq 0 ]] && echo 0 || echo 1)"

printf '\n'
if [[ "$FAIL" -eq 0 ]]; then
    printf 'check-hook-parity.test: %d passed, 0 failed\n' "$PASS"
    exit 0
fi

printf 'check-hook-parity.test: %d passed, %d FAILED\n' "$PASS" "$FAIL"
exit 1
