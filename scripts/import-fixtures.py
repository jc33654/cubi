#!/usr/bin/env python3
"""Copy captured hook envelopes into the test fixtures, with personal paths scrubbed.

Usage: scripts/import-fixtures.py <claude-code-version> [capture-dir] [--sessions id1,id2,…]

Only the listed sessions are imported (prefix match), so real work sessions recorded in the
capture directory never end up in the repo. Without --sessions everything is imported.

Reads ~/Library/Application Support/cubi/capture/*.jsonl (written by `cubi-hook --capture`),
replaces the home directory and user name, truncates long free text, and writes one pretty JSON
file per line to Tests/CubiKitTests/Fixtures/claude-<version>/<event>[-<tool>]-<n>.json.
Existing files for that version are replaced.
"""
import json
import os
import re
import shutil
import sys
from pathlib import Path

if len(sys.argv) < 2:
    sys.exit(__doc__)

args = [a for a in sys.argv[1:] if not a.startswith("--sessions")]
sessions = None
for a in sys.argv[1:]:
    if a.startswith("--sessions="):
        sessions = [x.strip() for x in a.split("=", 1)[1].split(",") if x.strip()]
version = args[0]
capture_dir = Path(args[1]) if len(args) > 1 else Path.home() / "Library/Application Support/cubi/capture"
repo = Path(__file__).resolve().parent.parent
out_dir = repo / "Tests/CubiKitTests/Fixtures" / f"claude-{version}"

home = str(Path.home())
user = os.path.basename(home)
TEXT_LIMIT = 200
TEXT_KEYS = {"last_assistant_message", "prompt", "message"}


def scrub(value):
    if isinstance(value, dict):
        out = {}
        for k, v in value.items():
            if k in TEXT_KEYS and isinstance(v, str) and len(v) > TEXT_LIMIT:
                v = v[:TEXT_LIMIT] + "…"
            if k == "tool_response" and isinstance(v, dict):
                v = {rk: (rv[:TEXT_LIMIT] + "…" if isinstance(rv, str) and len(rv) > TEXT_LIMIT else rv) for rk, rv in v.items()}
            out[k] = scrub(v)
        return out
    if isinstance(value, list):
        return [scrub(v) for v in value]
    if isinstance(value, str):
        value = value.replace(home, "/Users/me")
        value = re.sub(re.escape(user), "me", value)
        value = re.sub(r"/private/tmp/claude-\d+/", "/private/tmp/claude-501/", value)
        return value
    return value


if out_dir.exists():
    shutil.rmtree(out_dir)
out_dir.mkdir(parents=True)

count = 0
skipped = 0
for src in sorted(capture_dir.glob("*.jsonl")):
    stem = src.stem.removeprefix("claude-code-")
    n = 0
    for line in src.read_text(encoding="utf-8").splitlines():
        if not line.strip():
            continue
        raw = json.loads(line)
        payload = raw.get("payload")
        # Hand-fed test payloads (no session_id) are not real Claude Code events.
        if not isinstance(payload, dict) or not payload.get("session_id"):
            skipped += 1
            continue
        if sessions is not None and not any(payload["session_id"].startswith(x) for x in sessions):
            skipped += 1
            continue
        n += 1
        envelope = scrub(raw)
        dest = out_dir / f"{stem}-{n}.json"
        dest.write_text(json.dumps(envelope, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
        count += 1

print(f"wrote {count} fixtures to {out_dir.relative_to(repo)} (skipped {skipped} without session_id)")
