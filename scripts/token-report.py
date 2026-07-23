#!/usr/bin/env python3
# SPDX-FileCopyrightText: 2026 Mattia Egloff <mattia.egloff@pm.me>
# SPDX-License-Identifier: GPL-3.0-or-later
#
# Weekly Claude Code cost-vs-output report. Read-only.
#
# Answers "are we spending more tokens for fewer results?" empirically by
# joining two sources:
#   1. Session transcripts (~/.claude/projects/*<project>*/**/*.jsonl) —
#      per-message token usage. NESTED jsonl (in a session subdir) are
#      subagent/sidechain transcripts; counted as subagent spend. Missing
#      them is the exact blind spot that made a first-pass analysis read
#      "0% subagent" while subagents were 61% of the worst week's cost.
#   2. git log across all workspace repos — commits + lines changed, the
#      "results" proxy.
#
# Cost is COST-WEIGHTED "effective units" via published Anthropic price
# multipliers (base input token = 1) so cheap cache reads don't drown out
# expensive generation: output=5, cache_read=0.1, cache_write_5m=1.25,
# cache_write_1h=2. Absolute $ is intentionally not computed — the signal
# is the TREND (cost-per-commit and subagent %), which is retention-robust
# even though only recent transcripts survive on disk.
#
# Usage:
#   scripts/scripts/token-report.py [workspace_root] [project_match]
# Defaults: workspace_root=CWD, project_match=basename(workspace_root).

import os
import re
import sys
import json
import glob
import argparse
import subprocess
import collections
import datetime
from pathlib import Path

SCRIPT_DIRECTORY = Path(__file__).resolve().parent
if str(SCRIPT_DIRECTORY) not in sys.path:
    sys.path.insert(0, str(SCRIPT_DIRECTORY))

from agent_telemetry import append_receipt
from agent_telemetry_backfill import BackfillConfig, backfill, load_or_create_salt

W = dict(inp=1.0, cw5=1.25, cw1h=2.0, cr=0.1, out=5.0)


def iso_week(day):
    y, w = datetime.date.fromisoformat(day).isocalendar()[:2]
    return f"{y}-W{w:02d}"


def token_side(project_match, claude_home=None):
    """Return {day: {eff, out, msgs, subagent_eff, models:Counter}}."""
    base = os.path.join(
        os.fspath(claude_home or os.path.expanduser("~/.claude")), "projects"
    )
    dirs = glob.glob(os.path.join(base, f"*{project_match}*"))
    per = collections.defaultdict(lambda: dict(
        eff=0.0, out=0, msgs=0, sub=0.0, models=collections.Counter()))
    files = nested = 0
    for d in dirs:
        droot = d.rstrip("/")
        for root, _sub, names in os.walk(d):
            is_nested = root.rstrip("/") != droot
            for name in names:
                if not name.endswith(".jsonl"):
                    continue
                files += 1
                nested += 1 if is_nested else 0
                try:
                    fh = open(os.path.join(root, name), encoding="utf-8",
                              errors="ignore")
                except OSError:
                    continue
                seen_messages = set()
                for line in fh:
                    line = line.strip()
                    if not line:
                        continue
                    try:
                        rec = json.loads(line)
                    except Exception:
                        continue
                    if rec.get("type") != "assistant":
                        continue
                    ts = rec.get("timestamp")
                    msg = rec.get("message")
                    if not ts or not isinstance(msg, dict):
                        continue
                    message_id = msg.get("id")
                    if message_id and message_id in seen_messages:
                        continue
                    if message_id:
                        seen_messages.add(message_id)
                    day = ts[:10]
                    u = msg.get("usage") or {}
                    inp = u.get("input_tokens", 0)
                    out = u.get("output_tokens", 0)
                    cr = u.get("cache_read_input_tokens", 0)
                    cc = u.get("cache_creation", {}) or {}
                    cw5 = cc.get("ephemeral_5m_input_tokens", 0)
                    cw1h = cc.get("ephemeral_1h_input_tokens", 0)
                    if not cw5 and not cw1h:
                        cw5 = u.get("cache_creation_input_tokens", 0)
                    eff = (inp * W["inp"] + out * W["out"] + cr * W["cr"]
                           + cw5 * W["cw5"] + cw1h * W["cw1h"])
                    p = per[day]
                    p["eff"] += eff
                    p["out"] += out
                    p["msgs"] += 1
                    p["models"][msg.get("model", "?")] += eff
                    if is_nested or rec.get("isSidechain"):
                        p["sub"] += eff
                fh.close()
    return per, files, nested


def kimi_token_side(project_match, kimi_home=None):
    """Kimi Code sessions, same per-day shape as token_side().

    Layout: ~/.kimi-code/sessions/wd_<repo>_<hash>/session_*/agents/<name>/
    wire.jsonl. Each record: {type, event, time(epoch-ms)}; event.usage =
    {inputOther, output, inputCacheRead, inputCacheCreation}. An agent dir
    named other than 'main' is a subagent.
    """
    base = os.path.join(
        os.fspath(kimi_home or os.path.expanduser("~/.kimi-code")), "sessions"
    )
    per = collections.defaultdict(lambda: dict(
        eff=0.0, out=0, msgs=0, sub=0.0, models=collections.Counter()))
    files = nested = 0
    for sess in glob.glob(os.path.join(base, f"wd_*{project_match}*")):
        for root, _sub, names in os.walk(sess):
            if "wire.jsonl" not in names:
                continue
            is_sub = (os.path.basename(os.path.dirname(root)) == "agents"
                      and os.path.basename(root) != "main")
            files += 1
            nested += 1 if is_sub else 0
            try:
                fh = open(os.path.join(root, "wire.jsonl"),
                          encoding="utf-8", errors="ignore")
            except OSError:
                continue
            for line in fh:
                line = line.strip()
                if not line:
                    continue
                try:
                    rec = json.loads(line)
                except Exception:
                    continue
                ev = rec.get("event")
                t = rec.get("time")
                if not isinstance(ev, dict):
                    ev = rec
                if not t:
                    continue
                u = ev.get("usage")
                if not isinstance(u, dict):
                    continue
                day = datetime.datetime.fromtimestamp(
                    t / 1000, datetime.timezone.utc).date().isoformat()
                eff = (u.get("inputOther", 0) * W["inp"]
                       + u.get("output", 0) * W["out"]
                       + u.get("inputCacheRead", 0) * W["cr"]
                       + u.get("inputCacheCreation", 0) * W["cw5"])
                p = per[day]
                p["eff"] += eff
                p["out"] += u.get("output", 0)
                p["msgs"] += 1
                p["models"][ev.get("model", "kimi")] += eff
                if is_sub:
                    p["sub"] += eff
            fh.close()
    return per, files, nested


def codex_token_side(codex_home=None, project_match=None):
    """Read final cumulative token counts from Codex rollout metadata.

    Rollouts emit cumulative ``event_msg/token_count`` records. Only the
    final record per rollout is counted, so intermediate snapshots cannot
    inflate totals. Prompt and response bodies are never inspected or
    retained.
    """
    base = Path(codex_home or Path.home() / ".codex") / "sessions"
    per = collections.defaultdict(lambda: dict(
        eff=0.0, out=0, msgs=0, sub=0.0, models=collections.Counter()))
    files = 0
    if not base.is_dir():
        return per, files, 0

    for rollout in base.rglob("rollout-*.jsonl"):
        final_usage = None
        day = None
        session_cwd = None
        try:
            with rollout.open(encoding="utf-8", errors="ignore") as fh:
                for line in fh:
                    try:
                        record = json.loads(line)
                    except json.JSONDecodeError:
                        continue
                    payload = record.get("payload") or {}
                    if record.get("type") == "session_meta":
                        session_cwd = payload.get("cwd")
                        continue
                    if record.get("type") != "event_msg":
                        continue
                    if payload.get("type") != "token_count":
                        continue
                    usage = (payload.get("info") or {}).get("total_token_usage")
                    if not isinstance(usage, dict):
                        continue
                    final_usage = usage
                    timestamp = record.get("timestamp")
                    if isinstance(timestamp, str) and len(timestamp) >= 10:
                        day = timestamp[:10]
        except OSError:
            continue

        if not final_usage or not day:
            continue
        if (project_match and session_cwd
                and project_match not in str(session_cwd)):
            continue
        files += 1
        input_tokens = final_usage.get("input_tokens", 0)
        cached_input = final_usage.get("cached_input_tokens", 0)
        output_tokens = final_usage.get("output_tokens", 0)
        p = per[day]
        uncached_input = max(0, input_tokens - cached_input)
        p["eff"] += uncached_input + output_tokens * W["out"] + cached_input * W["cr"]
        p["out"] += output_tokens
        p["msgs"] += 1

    return per, files, 0


def results_side(workspace_root):
    """Return {day: (commits, lines_changed)} across all repos."""
    repos = [workspace_root] + glob.glob(os.path.join(workspace_root, "*/"))
    commits = collections.Counter()
    lines = collections.Counter()
    for r in repos:
        if not os.path.isdir(os.path.join(r, ".git")):
            continue
        try:
            out = subprocess.run(
                ["git", "-C", r, "log", "--since=8 weeks ago",
                 "--pretty=format:C%ad", "--date=short", "--numstat"],
                capture_output=True, text=True, timeout=60).stdout
        except Exception:
            continue
        cur = None
        for ln in out.splitlines():
            if ln.startswith("C") and re.match(r"C\d{4}-\d{2}-\d{2}$", ln):
                cur = ln[1:]
                commits[cur] += 1
            elif cur and "\t" in ln:
                a, dd = ln.split("\t")[:2]
                if a.isdigit():
                    lines[cur] += int(a)
                if dd.isdigit():
                    lines[cur] += int(dd)
    return commits, lines


def summary_main(arguments=None):
    arguments = list(arguments or [])
    root = os.path.abspath(arguments[0] if arguments else os.getcwd())
    # Default match strips a trailing worktree suffix ("vauchi-1" -> "vauchi")
    # so all worktrees/checkouts of the same project are aggregated.
    match = arguments[1] if len(arguments) > 1 else re.sub(
        r"-\d+$", "", os.path.basename(root))
    this_week = iso_week(datetime.date.today().isoformat())
    per_c, files_c, nested_c = token_side(match)
    per_k, files_k, nested_k = kimi_token_side(match)
    per_x, files_x, nested_x = codex_token_side(project_match=match)
    commits, lines = results_side(root)
    if not per_c and not per_k and not per_x:
        print(f"No transcripts found for match '*{match}*' under "
              f"~/.claude/projects, ~/.kimi-code/sessions, or ~/.codex/sessions. "
              f"Pass a match arg.")
        return 1

    eff_c = sum(p["eff"] for p in per_c.values())
    eff_k = sum(p["eff"] for p in per_k.values())
    eff_x = sum(p["eff"] for p in per_x.values())
    wk = collections.defaultdict(lambda: dict(
        eff=0.0, out=0, msgs=0, sub=0.0, com=0, lin=0))
    for per in (per_c, per_k, per_x):
        for day, p in per.items():
            w = wk[iso_week(day)]
            w["eff"] += p["eff"]
            w["out"] += p["out"]
            w["msgs"] += p["msgs"]
            w["sub"] += p["sub"]
    for day, c in commits.items():
        wk[iso_week(day)]["com"] += c
    for day, ln in lines.items():
        wk[iso_week(day)]["lin"] += ln

    nested = nested_c + nested_k + nested_x
    print(f"Agent cost-vs-output — project '*{match}*'  "
          f"(Claude {files_c} + Kimi {files_k} + Codex {files_x} transcripts, "
          f"{nested} subagent)\n")
    print("Cost = effective units (output×5, cache-read×0.1, "
          "cache-write×1.25–2), all harnesses combined. Trend matters.\n")
    hdr = ("week", "eff_M", "commits", "linesΔ", "cost/commit_k",
           "subagent%", "eff/msg_k")
    print("{:<9} {:>7} {:>8} {:>8} {:>14} {:>10} {:>10}".format(*hdr))
    print("-" * 74)
    weeks = sorted(wk)
    for k in weeks:
        w = wk[k]
        eff = w["eff"]
        cpc = eff / w["com"] / 1e3 if w["com"] else 0
        subp = w["sub"] / eff * 100 if eff else 0
        epm = eff / w["msgs"] / 1e3 if w["msgs"] else 0
        print("{:<9} {:>7.0f} {:>8} {:>8} {:>14.0f} {:>9.0f}% {:>10.1f}"
              .format(k, eff / 1e6, w["com"], w["lin"], cpc, subp, epm))

    # last-2-weeks vs prior-2-weeks verdict on cost/commit (the robust metric).
    # Only weeks with real transcript AND commit data are comparable; the
    # current (partial) week is excluded — its commits lag its token spend.
    comparable = [k for k in weeks
                  if k != this_week and wk[k]["eff"] > 0 and wk[k]["com"] > 0]
    if len(comparable) >= 4:
        def cpc_of(ws):
            e = sum(wk[x]["eff"] for x in ws)
            c = sum(wk[x]["com"] for x in ws)
            return (e / c / 1e3) if c else 0
        recent, prior = comparable[-2:], comparable[-4:-2]
        r, p = cpc_of(recent), cpc_of(prior)
        print("\nVerdict (cost per commit, k-units):")
        print(f"  last 2 wk {recent}: {r:,.0f}")
        print(f"  prior 2wk {prior}: {p:,.0f}")
        if p:
            delta = (r - p) / p * 100
            worse = delta > 15
            print(f"  → {'WORSE' if worse else 'stable/better'} "
                  f"({delta:+.0f}%). "
                  + ("Check the subagent% column — that's usually the driver."
                     if worse else "Impression of 'more for less' not supported."))
    total = eff_c + eff_k + eff_x or 1
    print("\nBy harness (effective units, all weeks):")
    print(f"  Claude Code : {eff_c/1e6:8.1f}M  ({eff_c/total*100:4.0f}%)")
    print(f"  Kimi Code   : {eff_k/1e6:8.1f}M  ({eff_k/total*100:4.0f}%)")
    print(f"  Codex       : {eff_x/1e6:8.1f}M  ({eff_x/total*100:4.0f}%)")
    print("\nNote: transcript retention is partial; raw eff_M for sparse "
          "weeks understates. cost/commit and subagent% are the signal.")
    return 0


def backfill_main(arguments):
    parser = argparse.ArgumentParser(prog="token-report backfill")
    parser.add_argument("--since")
    parser.add_argument("--workspace-root", default=os.getcwd())
    parser.add_argument("--output")
    parser.add_argument("--salt-file")
    parser.add_argument("--claude-home", default=str(Path.home() / ".claude"))
    parser.add_argument("--kimi-home", default=str(Path.home() / ".kimi-code"))
    parser.add_argument("--codex-home", default=str(Path.home() / ".codex"))
    options = parser.parse_args(arguments)
    workspace = Path(options.workspace_root).resolve()
    local_directory = workspace / "tmp/session-telemetry"
    output = Path(options.output or local_directory / "timeline-v1.jsonl")
    salt_file = Path(options.salt_file or local_directory / ".salt")
    since = (
        datetime.datetime.fromisoformat(options.since.replace("Z", "+00:00"))
        if options.since
        else datetime.datetime.now(datetime.timezone.utc)
        - datetime.timedelta(weeks=4)
    )
    if since.tzinfo is None:
        since = since.replace(tzinfo=datetime.timezone.utc)
    result = backfill(
        BackfillConfig(
            workspace_root=workspace,
            since=since,
            output=output,
            salt_file=salt_file,
            claude_home=Path(options.claude_home),
            kimi_home=Path(options.kimi_home),
            codex_home=Path(options.codex_home),
        )
    )
    print(json.dumps(result, sort_keys=True))
    return 0


def receipt_main(arguments):
    parser = argparse.ArgumentParser(prog="token-report receipt")
    parser.add_argument("--session", required=True)
    parser.add_argument("--type", required=True)
    parser.add_argument("--outcome", required=True)
    parser.add_argument("--corrections", required=True, type=int)
    parser.add_argument(
        "--output", default="tmp/session-telemetry/receipts.jsonl"
    )
    parser.add_argument("--salt-file", default="tmp/session-telemetry/.salt")
    options = parser.parse_args(arguments)
    salt = load_or_create_salt(Path(options.salt_file))
    receipt = append_receipt(
        Path(options.output),
        session_id=options.session,
        session_type=options.type,
        outcome=options.outcome,
        corrections=options.corrections,
        salt=salt,
    )
    print(json.dumps(receipt, sort_keys=True))
    return 0


def main(arguments=None):
    arguments = list(sys.argv[1:] if arguments is None else arguments)
    if arguments and arguments[0] == "backfill":
        return backfill_main(arguments[1:])
    if arguments and arguments[0] == "receipt":
        return receipt_main(arguments[1:])
    if arguments and arguments[0] == "summary":
        return summary_main(arguments[1:])
    return summary_main(arguments)


if __name__ == "__main__":
    raise SystemExit(main())
