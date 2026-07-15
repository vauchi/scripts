#!/usr/bin/env bash
# SPDX-FileCopyrightText: 2026 Mattia Egloff <mattia.egloff@pm.me>
# SPDX-License-Identifier: GPL-3.0-or-later
#
# Test runner for `scripts/scripts/semsearch.py`.
#
# semsearch answers semantic "find code related to X" locally (Ollama
# embeddings + sqlite), replacing frontier search-agent spawns. This test
# exercises the DETERMINISTIC core with a STUB embedder (no Ollama needed):
# chunking, cosine ranking, and the sqlite index round-trip. The live embed
# call is preflight-guarded at runtime (same fail-loud path as tell-me-about)
# and not exercised here.
#
# Run: bash scripts/scripts/tests/semsearch.test.sh

set -euo pipefail

set -uo pipefail

DIR="$(cd "$(dirname "$0")/.." && pwd)"
SCRIPT="$DIR/semsearch.py"

if [[ ! -f "$SCRIPT" ]]; then
    echo "FATAL: $SCRIPT missing (not implemented yet — RED)" >&2
    exit 1
fi

python3 - "$SCRIPT" <<'PY'
import sys, importlib.util, tempfile, os

spec = importlib.util.spec_from_file_location("semsearch", sys.argv[1])
m = importlib.util.module_from_spec(spec)
spec.loader.exec_module(m)

passed = failed = 0
def check(name, cond):
    global passed, failed
    if cond:
        print(f"  PASS  {name}"); passed += 1
    else:
        print(f"  FAIL  {name}"); failed += 1

# --- cosine ---
check("cosine identical == 1", abs(m.cosine([1,2,3],[1,2,3]) - 1.0) < 1e-9)
check("cosine orthogonal == 0", abs(m.cosine([1,0],[0,1])) < 1e-9)
check("cosine zero-vector safe (no div0)", m.cosine([0,0],[1,1]) == 0.0)

# --- chunking: splits, keeps 1-based start lines, non-empty text ---
text = "\n".join(f"line{i}" for i in range(1, 26))  # 25 lines
chunks = m.chunk_file("foo.rs", text, window=10, overlap=2)
check("chunk_file returns >=3 windows for 25 lines/win10", len(chunks) >= 3)
check("first chunk starts at line 1", chunks[0][0] == 1)
check("chunk start lines are 1-based & increasing",
      all(chunks[i][0] < chunks[i+1][0] for i in range(len(chunks)-1)))
check("every chunk has text", all(c[1].strip() for c in chunks))

# --- index round-trip + ranking with a STUB embedder ---
# Stub: map text to a 3-d vector by keyword presence so ranking is knowable.
def stub_embed(texts):
    out = []
    for t in texts:
        tl = t.lower()
        out.append([
            1.0 if "crypto" in tl else 0.0,
            1.0 if "relay"  in tl else 0.0,
            1.0 if "avatar" in tl else 0.0,
        ])
    return out

with tempfile.TemporaryDirectory() as d:
    db = os.path.join(d, "idx.db")
    docs = [
        ("a.rs", 1, "fn derive_key() { /* crypto hkdf */ }"),
        ("b.rs", 1, "fn send_to_relay() { /* relay mailbox */ }"),
        ("c.rs", 1, "fn set_avatar() { /* avatar webp */ }"),
        ("adr-007-crypto.md", 1, "crypto hkdf domain separation decision"),
    ]
    m.store_chunks(db, docs, stub_embed)
    check("index persisted 4 rows", m.index_count(db) == 4)

    hits = m.query_index(db, "crypto key derivation", stub_embed, k=2)
    check("top hit is a crypto chunk", hits and hits[0]["path"] in ("a.rs", "adr-007-crypto.md"))
    check("query returns <=k results", len(hits) <= 2)

    hits2 = m.query_index(db, "relay server mailbox", stub_embed, k=1)
    check("relay query ranks relay chunk first", hits2[0]["path"] == "b.rs")

    # --code filter: markdown docs excluded, code still returned/ranked
    hc = m.query_index(db, "crypto", stub_embed, k=5, code_only=True)
    check("code_only drops every .md hit", all(not h["path"].endswith(".md") for h in hc))
    check("code_only still returns the crypto code chunk", hc and hc[0]["path"] == "a.rs")
    hd = m.query_index(db, "crypto", stub_embed, k=5)
    check("default (no filter) still includes the .md",
          any(h["path"].endswith(".md") for h in hd))

print()
if failed == 0:
    print(f"semsearch.test: {passed} passed, 0 failed"); sys.exit(0)
else:
    print(f"semsearch.test: {passed} passed, {failed} FAILED"); sys.exit(1)
PY
