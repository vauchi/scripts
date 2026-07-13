#!/usr/bin/env python3
# SPDX-FileCopyrightText: 2026 Mattia Egloff <mattia.egloff@pm.me>
# SPDX-License-Identifier: GPL-3.0-or-later
#
# Local semantic code search. Answers "find code related to <X>" by
# cosine-ranking Ollama embeddings of source chunks stored in sqlite —
# NO API tokens, no frontier search-agent spawn. grep covers exact
# matches; this covers the semantic ones.
#
# Pure-Python core (chunking / cosine / sqlite) is deterministic and unit
# tested via a stub embedder; the live embed call is fail-loud preflight
# guarded, same as tell-me-about.sh.
#
# Usage:
#   scripts/scripts/semsearch.py index [root]        # build/refresh index
#   scripts/scripts/semsearch.py query "<question>"  # top-K locations
#
# Env: SEMSEARCH_MODEL (default nomic-embed-text), OLLAMA_HOST
#      (default http://localhost:11434), SEMSEARCH_DB, SEMSEARCH_AUTOPULL=1.

import os
import sys
import json
import math
import sqlite3
import hashlib
import urllib.request
import urllib.error

MODEL = os.environ.get("SEMSEARCH_MODEL", "nomic-embed-text")
OLLAMA = os.environ.get("OLLAMA_HOST", "http://localhost:11434").rstrip("/")
SRC_EXT = {".rs", ".swift", ".kt", ".kts", ".md", ".sh", ".just",
           ".feature", ".toml", ".ts", ".tsx", ".py"}
SKIP_DIRS = {"target", ".git", "node_modules", "DerivedData", ".cache",
             "build", ".venv", "vendor"}


# ── pure core (unit-tested) ─────────────────────────────────────────────
def cosine(a, b):
    """Cosine similarity; 0.0 when either vector has zero norm (no div0)."""
    dot = sum(x * y for x, y in zip(a, b))
    na = math.sqrt(sum(x * x for x in a))
    nb = math.sqrt(sum(y * y for y in b))
    if na == 0.0 or nb == 0.0:
        return 0.0
    return dot / (na * nb)


def chunk_file(path, text, window=60, overlap=12):
    """Split text into overlapping line windows.

    Returns [(start_line_1based, chunk_text), ...]. Overlap keeps a symbol
    that straddles a window boundary findable from either side.
    """
    lines = text.split("\n")
    if not any(l.strip() for l in lines):
        return []
    step = max(1, window - overlap)
    out = []
    for start in range(0, len(lines), step):
        piece = "\n".join(lines[start:start + window])
        if piece.strip():
            out.append((start + 1, piece))
        if start + window >= len(lines):
            break
    return out


def _connect(db):
    os.makedirs(os.path.dirname(os.path.abspath(db)), exist_ok=True)
    con = sqlite3.connect(db)
    con.execute("CREATE TABLE IF NOT EXISTS chunks("
                "path TEXT, start_line INTEGER, text TEXT, vec TEXT)")
    con.execute("CREATE TABLE IF NOT EXISTS files(path TEXT PRIMARY KEY, hash TEXT)")
    return con


def store_chunks(db, docs, embed_fn):
    """Persist (path, start_line, text) docs with their embeddings.

    embed_fn(list[str]) -> list[list[float]]. Kept injectable so tests can
    pass a deterministic stub with no Ollama.
    """
    con = _connect(db)
    vecs = embed_fn([d[2] for d in docs]) if docs else []
    con.executemany(
        "INSERT INTO chunks(path,start_line,text,vec) VALUES(?,?,?,?)",
        [(p, ln, tx, json.dumps(v)) for (p, ln, tx), v in zip(docs, vecs)])
    con.commit()
    con.close()


def index_count(db):
    con = _connect(db)
    n = con.execute("SELECT COUNT(*) FROM chunks").fetchone()[0]
    con.close()
    return n


def query_index(db, question, embed_fn, k=8):
    """Return top-k chunks by cosine to the embedded question."""
    qv = embed_fn([question])[0]
    con = _connect(db)
    rows = con.execute("SELECT path,start_line,text,vec FROM chunks").fetchall()
    con.close()
    scored = []
    for path, ln, tx, vec in rows:
        scored.append((cosine(qv, json.loads(vec)), path, ln, tx))
    scored.sort(key=lambda r: -r[0])
    return [{"path": p, "line": ln, "score": round(s, 4), "text": tx}
            for s, p, ln, tx in scored[:k]]


# ── Ollama embedder (runtime, preflight-guarded) ────────────────────────
def _http_json(url, payload=None, timeout=120):
    data = json.dumps(payload).encode() if payload is not None else None
    req = urllib.request.Request(url, data=data,
                                 headers={"Content-Type": "application/json"})
    with urllib.request.urlopen(req, timeout=timeout) as r:
        return json.loads(r.read())


def preflight():
    try:
        tags = _http_json(f"{OLLAMA}/api/tags")
    except Exception:
        sys.exit(f"Error: Ollama daemon not reachable at {OLLAMA}.\n"
                 "  Start it: ollama serve >/dev/null 2>&1 &")
    names = {m.get("name", "") for m in tags.get("models", [])}
    have = MODEL in names or any(n.split(":")[0] == MODEL.split(":")[0] for n in names)
    if not have:
        if os.environ.get("SEMSEARCH_AUTOPULL") == "1":
            os.system(f"ollama pull {MODEL}")
        else:
            sys.exit(f"Error: embed model '{MODEL}' not pulled.\n"
                     f"  One-time: ollama pull {MODEL}\n"
                     "  Or set SEMSEARCH_AUTOPULL=1.")


def embed_ollama(texts):
    # Prefer the batch /api/embed; fall back to per-text /api/embeddings.
    try:
        resp = _http_json(f"{OLLAMA}/api/embed", {"model": MODEL, "input": texts})
        if "embeddings" in resp:
            return resp["embeddings"]
    except Exception:
        pass
    out = []
    for t in texts:
        resp = _http_json(f"{OLLAMA}/api/embeddings", {"model": MODEL, "prompt": t})
        out.append(resp["embedding"])
    return out


# ── indexing driver ─────────────────────────────────────────────────────
def iter_source_files(root):
    for dirpath, dirs, files in os.walk(root):
        dirs[:] = [d for d in dirs if d not in SKIP_DIRS and not d.startswith(".")]
        for f in files:
            if os.path.splitext(f)[1] in SRC_EXT:
                yield os.path.join(dirpath, f)


def _sha1(path):
    h = hashlib.sha1()
    with open(path, "rb") as fh:
        h.update(fh.read())
    return h.hexdigest()


def do_index(db, root):
    preflight()
    con = _connect(db)
    known = dict(con.execute("SELECT path,hash FROM files").fetchall())
    con.close()
    changed, skipped = 0, 0
    for path in iter_source_files(root):
        rel = os.path.relpath(path, root)
        try:
            digest = _sha1(path)
        except OSError:
            continue
        if known.get(rel) == digest:
            skipped += 1
            continue
        try:
            text = open(path, encoding="utf-8", errors="ignore").read()
        except OSError:
            continue
        chunks = chunk_file(rel, text)
        if not chunks:
            continue
        con = _connect(db)
        con.execute("DELETE FROM chunks WHERE path=?", (rel,))
        con.close()
        store_chunks(db, [(rel, ln, tx) for ln, tx in chunks], embed_ollama)
        con = _connect(db)
        con.execute("INSERT OR REPLACE INTO files(path,hash) VALUES(?,?)", (rel, digest))
        con.commit()
        con.close()
        changed += 1
        print(f"  indexed {rel} ({len(chunks)} chunks)", file=sys.stderr)
    print(f"semsearch: {changed} files (re)indexed, {skipped} unchanged, "
          f"{index_count(db)} chunks total", file=sys.stderr)


def do_query(db, question, k=8):
    if not os.path.exists(db) or index_count(db) == 0:
        sys.exit("Index empty — run: just semindex")
    preflight()
    boiler = ("//", "#", "<!--", "/*", "*", "///", "//!")
    for h in query_index(db, question, embed_ollama, k):
        # Prefer the first meaningful line for the preview — skip license
        # headers and comment boilerplate that every file opens with.
        lines = [l for l in h["text"].split("\n") if l.strip()]
        first = next((l for l in lines
                      if not l.lstrip().startswith(boiler)), lines[0] if lines else "")
        print(f"{h['path']}:{h['line']}  [{h['score']}]  {first.strip()[:100]}")


def main(argv):
    db = os.environ.get("SEMSEARCH_DB",
                        os.path.join(os.getcwd(), ".cache", "semsearch.db"))
    if len(argv) < 2:
        sys.exit("usage: semsearch.py index [root] | query \"<question>\" [k]")
    cmd = argv[1]
    if cmd == "index":
        do_index(db, argv[2] if len(argv) > 2 else os.getcwd())
    elif cmd == "query":
        if len(argv) < 3:
            sys.exit("usage: semsearch.py query \"<question>\" [k]")
        k = int(argv[4]) if len(argv) > 4 and argv[4].isdigit() else 8
        do_query(db, argv[2], k)
    else:
        sys.exit(f"unknown command: {cmd}")


if __name__ == "__main__":
    main(sys.argv)
