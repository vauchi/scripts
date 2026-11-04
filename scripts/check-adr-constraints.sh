#!/usr/bin/env bash
# SPDX-FileCopyrightText: 2026 Mattia Egloff <mattia.egloff@pm.me>
#
# SPDX-License-Identifier: GPL-3.0-or-later
#
# Blocking checks for adr-constraints.md rules that a grep can decide
# (SC-64, private#972). Usage: check-adr-constraints.sh <core-checkout>
#
# Rules checked in the core crates' production code (`*/src`, Cargo.toml):
#   - no Platform trait in core (ADR-030/031)
#   - hardware depends on Core, never the reverse (owner 2026-10-30, #957)
#   - no hardware trait or mock hardware type in core (ADR-031, ADR-077);
#     a strategy seam's double such as MockProximityVerifier is not hardware
#   - no Transport generic on the user-facing Vauchi and AppEngine (ADR-030)
#   - Core never calls hardware: no core manifest names an OS hardware crate
#     (ADR-030/031, ADR-077)
# And in every .rs file, tests included, because tests are where mocks live:
#   - never mock crypto (ADR-002): no Mock/Fake/Stub/Dummy crypto type and no
#     hand-written impl of a crypto trait; a storage or relay double is fine
#
# Exits 1 naming each broken rule; exits 1 when the checkout is missing,
# so a wrong path cannot pass as "clean".

set -eu

CORE="${1:-}"
if [ -z "$CORE" ] || [ ! -d "$CORE" ]; then
    echo "check-adr-constraints: no core checkout at '${CORE}'" >&2
    exit 1
fi

HARDWARE_WORDS='Ble|BLE|Nfc|NFC|Accelerometer|Camera|Audio|Location|Biometric|Usb|USB|Wifi|WiFi'
HARDWARE_ROLES='Backend|Verifier|Driver|Port|Adapter|Hardware'
HARDWARE_CRATES='vauchi-hardware|vauchi-linux-hw|linux-hw|apple-hw|android-hw|windows-hw'
# BLE, NFC and smart cards, camera, audio, USB, serial, GPIO and input.
OS_HARDWARE_CRATES='btleplug|bluer|bluez-async|nfc1|pcsc|nokhwa|v4l|opencv|cpal|rodio|rusb|nusb|hidapi|serialport|rppal|evdev|objc2-core-bluetooth|objc2-av-foundation'
CRYPTO_WORDS='Cipher|Aead|Signer|Signature|Signing|Kdf|Hkdf|Hasher|Hash|Rng|Crypto|Encrypt|Decrypt|Ratchet|Seal|Keypair|KeyPair|Kem'
CRYPTO_TRAITS='RngCore|CryptoRng|CryptoRngCore|Signer|Verifier|Aead|AeadInPlace|AeadCore|KeyInit|Digest|Mac'

failures=0
report() {
    rule="$1"; hits="$2"
    [ -n "$hits" ] || return 0
    failures=$((failures + 1))
    printf 'adr-constraints: %s\n%s\n\n' "$rule" "$hits" >&2
}

# Production sources of every crate, never tests, benches or build output.
sources() {
    find "$CORE" -path '*/target' -prune -o -path '*/src/*' -name '*.rs' -print
}

grep_sources() {
    sources | while IFS= read -r file; do
        grep -n -E "$1" "$file" | sed "s|^|$file:|"
    done
}

report "no Platform trait in core (ADR-030/031)" \
    "$(grep_sources '(^|[^A-Za-z0-9_])trait[[:space:]]+Platform([^A-Za-z0-9_]|$)')"

report "hardware depends on Core, never the reverse (#957): a core crate names a hardware crate" \
    "$(find "$CORE" -path '*/target' -prune -o -name Cargo.toml -print \
        | while IFS= read -r manifest; do
            grep -n -E "^[[:space:]]*($HARDWARE_CRATES)[[:space:]]*=|package[[:space:]]*=[[:space:]]*\"($HARDWARE_CRATES)\"" \
                "$manifest" | sed "s|^|$manifest:|"
        done)"

report "no hardware trait or mock hardware type in core (ADR-031, ADR-077)" \
    "$(grep_sources "pub[[:space:]]+(trait|struct)[[:space:]]+(Mock)?($HARDWARE_WORDS)[A-Za-z0-9_]*($HARDWARE_ROLES)([^A-Za-z0-9_]|$)")"

report "no Transport generic on user-facing types (ADR-030): Vauchi and AppEngine take no type parameter" \
    "$(grep_sources 'pub[[:space:]]+struct[[:space:]]+(Vauchi|AppEngine)[[:space:]]*<')"

report "Core never calls hardware (ADR-030/031, ADR-077): a core crate names an OS hardware crate" \
    "$(find "$CORE" -path '*/target' -prune -o -name Cargo.toml -print \
        | while IFS= read -r manifest; do
            grep -n -E "^[[:space:]]*($OS_HARDWARE_CRATES)[[:space:]]*=|package[[:space:]]*=[[:space:]]*\"($OS_HARDWARE_CRATES)\"" \
                "$manifest" | sed "s|^|$manifest:|"
        done)"

report "never mock crypto (ADR-002): use real crypto operations" \
    "$(find "$CORE" -path '*/target' -prune -o -name '*.rs' -print | while IFS= read -r file; do
        grep -n -E "(struct|enum)[[:space:]]+(Mock|Fake|Stub|Dummy)[A-Za-z0-9_]*($CRYPTO_WORDS)|impl([[:space:]]*<[^>]*>)?[[:space:]]+([A-Za-z0-9_]+::)*($CRYPTO_TRAITS)([[:space:]]*<[^>]*>)?[[:space:]]+for[[:space:]]" \
            "$file" | sed "s|^|$file:|"
    done)"

if [ "$failures" -gt 0 ]; then
    echo "check-adr-constraints: $failures rule(s) broken; see _private/.claude/rules/adr-constraints.md" >&2
    exit 1
fi
echo "check-adr-constraints: clean"
