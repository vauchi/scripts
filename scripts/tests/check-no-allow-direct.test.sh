#!/usr/bin/env bash
# SPDX-FileCopyrightText: 2026 Mattia Egloff <mattia.egloff@pm.me>
#
# SPDX-License-Identifier: GPL-3.0-or-later

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT="$SCRIPT_DIR/../check-no-allow-direct.sh"

pass=0
fail=0

assert_exit() {
    local name="$1" expected="$2" actual="$3"
    if [[ "$expected" == "$actual" ]]; then
        printf '  PASS %s\n' "$name"
        pass=$((pass + 1))
    else
        printf '  FAIL %s — expected %s, got %s\n' \
            "$name" "$expected" "$actual" >&2
        fail=$((fail + 1))
    fi
}

run_fixture() {
    local content="$1"
    local path="${2:-src/runner.rs}"
    local root
    root="$(mktemp -d)"
    mkdir -p "$root/$(dirname "$path")"
    printf '%s\n' "$content" > "$root/$path"

    set +e
    "$SCRIPT" "$root" >/dev/null 2>&1
    result=$?
    set -e
    rm -rf "$root"
}

run_fixture 'command.env_remove("VAUCHI_ALLOW_DIRECT");'
assert_exit "explicit removal is allowed" 0 "$result"

run_fixture 'command.env("VAUCHI_ALLOW_DIRECT", "1");'
assert_exit "Rust environment injection is rejected" 1 "$result"

run_fixture 'extra_env.insert("VAUCHI_ALLOW_DIRECT".to_string(), "1".to_string());'
assert_exit "Rust map injection is rejected" 1 "$result"

run_fixture 'VAUCHI_ALLOW_DIRECT=1 vauchi sync' 'scripts/run.sh'
assert_exit "shell environment injection is rejected" 1 "$result"

run_fixture 'extra_env.insert("VAUCHI_ALLOW_DIRECT".to_string(), "1".to_string());' \
    'src/device/tests.rs'
assert_exit "test fixture injection is allowed" 0 "$result"

run_fixture 'let config = HttpTransportConfig { allow_direct: true };' \
    'tests/it/transport_isolation.rs'
assert_exit "explicit transport-isolation test is allowed" 0 "$result"

run_fixture 'pub allow_direct: bool,'
assert_exit "boolean field declaration is allowed" 0 "$result"

run_fixture 'let config = HttpTransportConfig { allow_direct: false };'
assert_exit "fail-closed production initializer is allowed" 0 "$result"

run_fixture 'config.allow_direct = false;'
assert_exit "fail-closed production assignment is allowed" 0 "$result"

run_fixture 'if config.allow_direct == false { return; }'
assert_exit "direct-mode comparison is allowed" 0 "$result"

run_fixture 'let config = HttpTransportConfig { allow_direct: key.is_none() };'
assert_exit "dynamic production direct fallback is rejected" 1 "$result"

run_fixture 'config.allow_direct = permit_direct;'
assert_exit "dynamic production direct assignment is rejected" 1 "$result"

run_fixture 'let config = HttpTransportConfig { allow_direct: false || permit_direct };'
assert_exit "false-prefixed production initializer is rejected" 1 "$result"

run_fixture 'config.allow_direct = false || permit_direct;'
assert_exit "false-prefixed production assignment is rejected" 1 "$result"

run_fixture 'let config = HttpTransportConfig { allow_direct };'
assert_exit "shorthand production direct initializer is rejected" 1 "$result"

run_fixture 'let transport = HttpTransportConfig::for_testing(url, 1000);'
assert_exit "production test constructor call is rejected" 1 "$result"

run_fixture 'let transport = HttpTransportConfig::for_testing(url, 1000);' \
    'tests/it/transport_isolation.rs'
assert_exit "test constructor call is allowed" 0 "$result"

run_fixture 'fn create_bootstrap_transport_direct() {
    let config = HttpTransportConfig { allow_direct: true };
}' 'vauchi-core/src/api/vauchi/sync_http.rs'
assert_exit "documented bootstrap initializer is allowed" 0 "$result"

run_fixture 'pub fn for_testing() {
    let config = HttpTransportConfig { allow_direct: true };
}' 'vauchi-core/src/network/http_transport.rs'
assert_exit "test constructor definition is allowed" 0 "$result"

# A `#[cfg(feature = "testing")]` hatch whose block CLOSES must not exempt
# the production code that follows it. These fixtures mirror the real shape
# of `Vauchi::build_relay_transport`, where the hatch sits 17 lines above a
# production `HttpTransportConfig` — well inside the 60-line look-back.
# Regression guard for the 2026-08-05 blind spot; a bare one-line fixture
# (see "dynamic production direct fallback" above) cannot reproduce it.

run_fixture 'pub fn build_relay_transport(&self, timeout_ms: u64) -> HttpTransport {
    #[cfg(feature = "testing")]
    if self.config.ohttp.allow_direct {
        return HttpTransport::new(HttpTransportConfig::for_testing(
            self.config.relay.server_url.clone(),
            timeout_ms,
        ));
    }

    let mut transport = HttpTransport::new(HttpTransportConfig {
        relay_url,
        timeout_ms,
        proxy: self.config.relay.proxy.clone(),
        allow_direct: self.ohttp_key.is_none(),
        pinned_certs,
    });
    transport
}' 'vauchi-core/src/api/vauchi/sync_http.rs'
assert_exit "dynamic fallback after a closed testing hatch is rejected" 1 "$result"

run_fixture 'pub fn build_relay_transport(&self, timeout_ms: u64) -> HttpTransport {
    #[cfg(feature = "testing")]
    if self.config.ohttp.allow_direct {
        return HttpTransport::new(HttpTransportConfig::for_testing(
            self.config.relay.server_url.clone(),
            timeout_ms,
        ));
    }

    let mut transport = HttpTransport::new(HttpTransportConfig {
        relay_url,
        timeout_ms,
        proxy: self.config.relay.proxy.clone(),
        allow_direct: false,
        pinned_certs,
    });
    transport
}' 'vauchi-core/src/api/vauchi/sync_http.rs'
assert_exit "for_testing inside an open testing hatch stays allowed" 0 "$result"

run_fixture 'mod tests {
    #[test]
    fn uses_direct() {
        let config = HttpTransportConfig { allow_direct: key.is_none() };
    }
}'
assert_exit "dynamic fallback inside mod tests stays allowed" 0 "$result"

run_fixture '#[test]
fn uses_direct() {
    let config = HttpTransportConfig { allow_direct: true };
}

pub fn production_path() {
    let config = HttpTransportConfig { allow_direct: key.is_none() };
}'
assert_exit "dynamic fallback after a closed test fn is rejected" 1 "$result"

# A sentinel whose block opens AND closes on one line must not exempt what
# follows. Tracking only the line's NET brace delta misses this: the depth
# returns to zero before the block ever registers as opened, so the sentinel
# stays in scope forever. Found by adversarial review of the first fix.

run_fixture '#[cfg(test)]
fn helper() {}

pub fn production_path() {
    let config = HttpTransportConfig { allow_direct: key.is_none() };
}'
assert_exit "dynamic fallback after a same-line cfg(test) block is rejected" 1 "$result"

run_fixture '#[test]
fn helper() {}

pub fn production_path() {
    let config = HttpTransportConfig { allow_direct: key.is_none() };
}'
assert_exit "dynamic fallback after a same-line test fn is rejected" 1 "$result"

# A sentinel on a `;`-terminated item guards that item only. Letting it
# exempt the rest of the file is a deliberate bypass anyone can write.

run_fixture '#[cfg(feature = "testing")]
use std::collections::HashMap;

pub fn production_path() {
    let config = HttpTransportConfig { allow_direct: key.is_none() };
}'
assert_exit "dynamic fallback after a cfg-gated use is rejected" 1 "$result"

run_fixture '#[cfg(test)]
use tempfile::TempDir;

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn t() {
        let config = HttpTransportConfig { allow_direct: key.is_none() };
    }
}'
assert_exit "a later sentinel still exempts genuine test code" 0 "$result"

# 70 filler lines: more than the old 60-line look-back window.
filler=$(for i in $(seq 1 70); do printf '        let _f%s = %s;\n' "$i" "$i"; done)

# core vauchi-platform/src/lib.rs:558 on 2026-09-25: a helper inside
# `#[cfg(test)] mod tests` whose opening sat 64 lines above it.
run_fixture "#[cfg(test)]
mod tests {
    use super::*;
    fn early() {
$filler
    }
    fn test_shred_sender() {
        let transport = HttpTransport::new(HttpTransportConfig::for_testing(
            \"http://localhost:8080\",
            1000,
        ));
    }
}"
assert_exit "test helper more than 60 lines into mod tests is allowed" 0 "$result"

run_fixture "#[cfg(test)]
mod tests {
    fn helper() {
$filler
    }
}

pub fn production_path() {
    let config = HttpTransportConfig { allow_direct: key.is_none() };
}"
assert_exit "production site far below a closed test module is rejected" 1 "$result"

# The guard ran with ripgrep absent and reported OK (2026-09-25: allyson's
# shell runner had no rg until _private 0cac5327). A guard whose tool is
# missing or broken must fail, not pass.
run_fixture_with_path() {
    local content="$1" path_dir="$2"
    local root
    root="$(mktemp -d)"
    mkdir -p "$root/src"
    printf '%s\n' "$content" > "$root/src/runner.rs"
    set +e
    output="$(PATH="$path_dir" "$SCRIPT" "$root" 2>&1)"
    result=$?
    set -e
    rm -rf "$root"
}

tools_dir="$(mktemp -d)"
for tool in bash env sed awk grep cat printf head tr cut dirname basename sort wc mktemp; do
    tool_path="$(command -v "$tool" 2>/dev/null)" && ln -s "$tool_path" "$tools_dir/$tool"
done

run_fixture_with_path 'let config = HttpTransportConfig { allow_direct: key.is_none() };' "$tools_dir"
assert_exit "missing ripgrep fails instead of passing" 2 "$result"
assert_exit "missing ripgrep is named in the error" 1 \
    "$(printf '%s' "$output" | grep -qi 'ripgrep' && echo 1 || echo 0)"

broken_rg_dir="$(mktemp -d)"
for tool in "$tools_dir"/*; do ln -s "$(readlink "$tool")" "$broken_rg_dir/$(basename "$tool")"; done
printf '#!/bin/sh\necho "PCRE2 is not available in this build of ripgrep." >&2\nexit 2\n' > "$broken_rg_dir/rg"
chmod +x "$broken_rg_dir/rg"
run_fixture_with_path 'let config = HttpTransportConfig { allow_direct: key.is_none() };' "$broken_rg_dir"
assert_exit "a failing ripgrep fails instead of passing" 2 "$result"
assert_exit "ripgrep's own error is shown" 1 \
    "$(printf '%s' "$output" | grep -q 'PCRE2 is not available' && echo 1 || echo 0)"
rm -rf "$tools_dir" "$broken_rg_dir"

printf '\n%d passed, %d failed\n' "$pass" "$fail"
[[ "$fail" -eq 0 ]]
