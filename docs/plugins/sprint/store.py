"""Local state of the sprint plugin: config, sprints, tickets, session bindings, work segments.

Everything lives as small JSON files under one directory (default
~/Library/Application Support/cubi/sprint, override with CUBI_SPRINT_DIR). Nothing here talks
to Jira or to cubi; that is sprint.py's job.
"""
import fcntl
import json
import os
import re
import subprocess
import sys
import time
import uuid
from pathlib import Path

DEFAULT_DIR = "~/Library/Application Support/cubi/sprint"
KEY_RE = re.compile(r"[A-Z][A-Z0-9_]+-[0-9]+")
LABEL_RE = re.compile(r"[A-Za-z0-9_-]{1,32}")
MEETING_KINDS = ("會議", "討論")
MAX_ENTRY = 24 * 3600
FILES = ("config.json", "sprints.json", "tickets.json", "bindings.json", "segments.json")

DEFAULT_CONFIG = {
    "site": "example.atlassian.net",
    "netrc": "~/.config/atlassian/netrc",
    "projectKey": "PROJ",
    # {project} and {label} are filled in; sprints are labels on the issues.
    "jql": 'project = {project} AND labels = "{label}" ORDER BY key',
    "pointsField": "customfield_10016",
    # A number field to push the actual points to; empty keeps them local.
    "actualPointsField": "",
    "reviewDir": "~/Documents/sprint-reviews",
}


class Store:
    """Holds an exclusive lock on the data directory from load to save: tick, session.info and
    the panel are separate processes, and the slow one must not overwrite the others' changes."""

    def __init__(self, root=None):
        self.root = Path(root or os.environ.get("CUBI_SPRINT_DIR") or DEFAULT_DIR).expanduser()
        self.root.mkdir(parents=True, exist_ok=True)
        self._lock = open(self.root / ".lock", "w")
        fcntl.flock(self._lock, fcntl.LOCK_EX)
        self._loaded = {}
        self.config = {**DEFAULT_CONFIG, **self._read("config.json", {})}
        self.sprints = self._read("sprints.json", {"current": None, "sprints": {}})
        self.tickets = self._read("tickets.json", {})
        self.bindings = self._read("bindings.json", {})
        self.segments = self._read("segments.json", {"sessions": {}, "manual": []})

    # ---------- files ----------

    def _read(self, name, default):
        path = self.root / name
        try:
            with open(path, encoding="utf-8") as f:
                data = json.load(f)
        except FileNotFoundError:
            data = default
        except json.JSONDecodeError as e:
            # Keep the broken file for the user to look at; never overwrite it with defaults silently.
            bad = path.with_name(f"{name}.bad-{int(time.time())}")
            os.replace(path, bad)
            print(f"{name} 不是合法 JSON（{e}），已搬到 {bad.name}，改用預設", file=sys.stderr)
            data = default
        self._loaded[name] = json.dumps(data, sort_keys=True)
        return data

    def _write(self, name, data):
        if json.dumps(data, sort_keys=True) == self._loaded.get(name):
            return
        tmp = self.root / (name + ".tmp")
        with open(tmp, "w", encoding="utf-8") as f:
            json.dump(data, f, ensure_ascii=False, indent=1, sort_keys=True)
        os.replace(tmp, self.root / name)

    def save(self):
        """Write what changed and release the lock; harmless to call twice."""
        if self._lock.closed:
            return
        for name, data in zip(FILES, (self.config, self.sprints, self.tickets, self.bindings, self.segments)):
            self._write(name, data)
        fcntl.flock(self._lock, fcntl.LOCK_UN)
        self._lock.close()

    # ---------- sprints and tickets ----------

    def current_sprint(self):
        label = self.sprints.get("current")
        return self.sprints["sprints"].get(label) if label else None

    def sprint(self, label):
        return self.sprints["sprints"].get(label)

    def new_sprint(self, label, name="", start="", end="", goal=""):
        if not LABEL_RE.fullmatch(label or ""):
            raise ValueError("sprint 標籤只能有英數、_、-，1–32 字（例如 Sprint7）")
        s = self.sprints["sprints"].setdefault(label, {"label": label, "keys": [], "review": empty_review()})
        s.update({"name": name or label, "start": start, "end": end, "goal": goal})
        self.sprints["current"] = label
        return s

    def ticket(self, key):
        return self.tickets.setdefault(key, {"key": key, "summary": "", "status": "", "done": False,
                                             "estimate": None, "actual": None, "doneAt": None, "notes": ""})

    def add_to_sprint(self, label, key):
        s = self.sprint(label)
        if s is not None and key not in s["keys"]:
            s["keys"].append(key)
        self.ticket(key)

    def browse_url(self, key):
        return f"https://{self.config['site']}/browse/{key}"

    # ---------- bindings ----------

    def extract_keys(self, *texts):
        """Issue keys of the configured project, in order of first appearance."""
        prefix = self.config["projectKey"].upper() + "-"
        found = []
        for text in texts:
            for k in KEY_RE.findall((text or "").upper()):
                if k.startswith(prefix) and k not in found:
                    found.append(k)
        return found

    def binding(self, session):
        """Refresh what the session is bound to from its name, branch and cwd; manual edits win."""
        sid = session["id"]
        rec = self.bindings.setdefault(sid, {"keys": [], "removed": [], "shares": {}})
        rec["name"] = session.get("name", "")
        rec["auto"] = self.extract_keys(session.get("name"), git_branch(session.get("cwd")), session.get("cwd"))
        return rec

    def bound_keys(self, rec):
        auto = [k for k in rec.get("auto", []) if k not in rec.get("removed", [])]
        return auto + [k for k in rec.get("keys", []) if k not in auto]

    def bind(self, sid, key):
        rec = self.bindings.setdefault(sid, {"keys": [], "removed": [], "shares": {}})
        if key in rec["removed"]:
            rec["removed"].remove(key)
        if key not in rec["keys"]:
            rec["keys"].append(key)

    def unbind(self, sid, key):
        rec = self.bindings.setdefault(sid, {"keys": [], "removed": [], "shares": {}})
        if key in rec["keys"]:
            rec["keys"].remove(key)
        if key in rec.get("auto", []) and key not in rec["removed"]:
            rec["removed"].append(key)
        rec["shares"].pop(key, None)

    def shares(self, rec):
        """Percent of the session's time per bound key: the user's split, else equal parts."""
        keys = self.bound_keys(rec)
        if not keys:
            return {}
        given = {k: float(v) for k, v in rec.get("shares", {}).items() if k in keys and float(v) > 0}
        total = sum(given.values())
        if set(given) == set(keys) and total > 0:
            return {k: round(v * 100 / total, 2) for k, v in given.items()}
        return {k: round(100 / len(keys), 2) for k in keys}

    def set_shares(self, sid, shares, since=None, until=None):
        rec = self.bindings.setdefault(sid, {"keys": [], "removed": [], "shares": {}})
        rec["shares"] = {k: float(v) for k, v in shares.items()}
        if since is not None:
            for start, seg in self.segments["sessions"].get(sid, {}).items():
                if float(start) >= since and (until is None or float(start) <= until):
                    seg["shares"] = self.shares(rec)

    # ---------- segments ----------

    def record_segments(self, session, shares):
        """Upsert the stretches cubi reports; the shares a stretch started with stay with it."""
        sess = self.segments["sessions"].setdefault(session["id"], {})
        for seg in session.get("segments", []):
            entry = sess.setdefault(str(int(seg["start"])), {"shares": shares})
            entry["end"] = seg["end"]
            entry["open"] = bool(seg.get("open"))
            entry["name"] = session.get("name", "")
            if not entry.get("shares"):
                entry["shares"] = shares

    def add_manual(self, key, start, minutes, kind="開發", note="", calendar=False):
        try:
            start, minutes = float(start), float(minutes)
        except (TypeError, ValueError):
            raise ValueError("開始時間與長度要是數字")
        if not (1 <= minutes <= MAX_ENTRY / 60) or start != start:
            raise ValueError("長度要在 1 分鐘到 24 小時之間")
        entry = {"id": uuid.uuid4().hex[:12], "key": key, "start": start, "end": start + minutes * 60,
                 "kind": kind, "note": note, "calendar": bool(calendar)}
        self.segments["manual"].append(entry)
        return entry

    def remove_manual(self, entry_id):
        before = len(self.segments["manual"])
        self.segments["manual"] = [m for m in self.segments["manual"] if m["id"] != entry_id]
        return len(self.segments["manual"]) < before

    def hours_by_key(self, since=None, until=None):
        """Seconds per key within [since, until]: session stretches split by their shares, manual
        entries whole. 'meeting' is the part of 'manual' whose kind is a meeting or discussion."""
        out = {}

        def bucket(key):
            return out.setdefault(key, {"session": 0.0, "manual": 0.0, "meeting": 0.0})

        for sess in self.segments["sessions"].values():
            for start, seg in sess.items():
                secs = overlap(float(start), seg["end"], since, until)
                for key, pct in (seg.get("shares") or {}).items():
                    bucket(key)["session"] += secs * pct / 100
        for m in self.segments["manual"]:
            secs = overlap(m["start"], m["end"], since, until)
            bucket(m["key"])["manual"] += secs
            if m.get("kind") in MEETING_KINDS:
                bucket(m["key"])["meeting"] += secs
        for b in out.values():
            b["total"] = b["session"] + b["manual"]
        return out

    def calendar_entries(self, now, window=48 * 3600):
        """What cubi should have on the calendar: finished stretches with keys, and manual entries
        flagged for it, from the last `window` seconds. Re-sent every tick; cubi dedupes."""
        entries = []
        for m in self.segments["manual"]:
            if m.get("calendar") and m["end"] >= now - window and 60 <= m["end"] - m["start"] <= MAX_ENTRY:
                entries.append({
                    "title": f"{m['key']} {m.get('note') or ''}（{m.get('kind', '')}）".replace("  ", " "),
                    "start": m["start"], "end": m["end"],
                    "notes": self.browse_url(m["key"]),
                    "marker": f"sprint:manual:{m['id']}",
                })
        for sid, sess in self.segments["sessions"].items():
            for start, seg in sess.items():
                keys = list((seg.get("shares") or {}).keys())
                length = seg["end"] - float(start)
                if seg.get("open") or not keys or seg["end"] < now - window or not 60 <= length <= MAX_ENTRY:
                    continue
                # The session name often starts with the keys themselves; say each once.
                name = " ".join(w for w in (seg.get("name") or "").split() if w.upper() not in keys)
                entries.append({
                    "title": " ".join(keys) + (" " + name if name else ""),
                    "start": float(start), "end": seg["end"],
                    "notes": "\n".join(self.browse_url(k) for k in keys),
                    "marker": f"sprint:{sid[:8]}:{int(float(start))}",
                })
        # Newest first, manual entries ahead of stretches, so a busy week never starves a fresh meeting.
        entries.sort(key=lambda e: (not e["marker"].startswith("sprint:manual:"), -e["start"]))
        return entries[:50]


def empty_review():
    return {"wentWell": [], "toImprove": [], "suggestions": [], "thanks": []}


def overlap(start, end, since, until):
    lo = start if since is None else max(start, since)
    hi = end if until is None else min(end, until)
    return max(0.0, hi - lo)


def git_branch(cwd):
    if not cwd:
        return None
    try:
        r = subprocess.run(["/usr/bin/git", "-C", cwd, "rev-parse", "--abbrev-ref", "HEAD"],
                           capture_output=True, text=True, timeout=3)
    except (OSError, subprocess.SubprocessError):
        return None
    return r.stdout.strip() if r.returncode == 0 else None
