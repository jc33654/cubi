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
from pathlib import Path

from hours import SESSION_KIND, HoursMixin, overlap, subtract  # noqa: F401  (re-exported)
from review import MEETING_KINDS, remaining_seconds, tone_for  # noqa: F401  (re-exported)
from timers import MAX_ENTRY, ORPHAN_AFTER, TIMER_KIND, TimerMixin  # noqa: F401

DEFAULT_DIR = "~/Library/Application Support/cubi/sprint"
KEY_RE = re.compile(r"[A-Z][A-Z0-9_]+-[0-9]+")
LABEL_RE = re.compile(r"[A-Za-z0-9_-]{1,32}")
FILES = ("config.json", "sprints.json", "tickets.json", "bindings.json", "segments.json")

DEFAULT_CONFIG = {
    "site": "example.atlassian.net",
    "netrc": "~/.config/atlassian/netrc",
    # One or more, comma separated; issue keys of these projects are recognised.
    "projectKey": "PROJ",
    # {projects} (all, comma separated), {project} (the first) and {label} are filled in; sprints
    # are labels on the issues.
    "jql": 'project in ({projects}) AND labels = "{label}" AND assignee = currentUser() ORDER BY key',
    "pointsField": "customfield_10016",
    # A number field to push the actual points (hours ÷ hours-per-point) to; empty: no push button.
    "actualPointsField": "",
    # A number field to push the hours worked on the ticket to; empty: no push button.
    "actualHoursField": "",
    # Write those hours on its own whenever a timer stops or a manual stretch is added, changed or
    # removed (off: only the button does). It replaces the field, someone else's figure included.
    "autoPushHours": False,
    # One point of estimate is this many hours of work.
    "hoursPerPoint": 8,
    # The Monday some sprint began: periods are counted from it in two-week steps, to propose
    # dates. Empty: nothing is proposed.
    "cadenceAnchor": "",
    # The "Sprint review" calendar event on each sprint's review day: when it starts (HH:MM;
    # empty: no event) and how many minutes it runs.
    "reviewEventStart": "10:00",
    "reviewEventMinutes": 30,
    "reviewDir": "~/Documents/sprint-reviews",
    # Where the "用 Claude 整理回顧" session opens.
    "reviewSessionDir": "~/Documents",
    # Where the "AI 估點" session opens and reads code. Empty until the user picks one: everything
    # in it is readable to that session.
    "estimateSessionDir": "",
}


class Store(TimerMixin, HoursMixin):
    """Holds an exclusive lock on the data directory from load to save: tick, session.info and
    the panel are separate processes, and the slow one must not overwrite the others' changes."""

    def __init__(self, root=None):
        self.root = Path(root or os.environ.get("CUBI_SPRINT_DIR") or DEFAULT_DIR).expanduser()
        self.root.mkdir(parents=True, exist_ok=True)
        self._take()

    def _take(self):
        """Take the lock and read the files as they are now."""
        self._lock = open(self.root / ".lock", "w")
        fcntl.flock(self._lock, fcntl.LOCK_EX)
        self._loaded = {}
        self.warnings = []
        self.config = {**DEFAULT_CONFIG, **self._read("config.json", {})}
        self.sprints = self._read("sprints.json", {"current": None, "sprints": {}})
        self.tickets = self._read("tickets.json", {})
        self.bindings = self._read("bindings.json", {})
        self.segments = self._read("segments.json", {"sessions": {}, "manual": []})
        self.segments.setdefault("timers", {})
        self._taken = self._dump()

    def _data(self):
        return (self.config, self.sprints, self.tickets, self.bindings, self.segments)

    def _dump(self):
        return [json.dumps(data, sort_keys=True) for data in self._data()]

    def away(self, work, save_first=False):
        """Run `work()` — a call to Jira, which may take its whole timeout — without the lock, so
        the session card and tick are not kept waiting behind it; then take the lock again and
        read the files afresh. Whatever the caller wants stored it applies after this returns, to
        the data as it is then: nothing another action wrote in the meantime is overwritten.
        Changes made before going away would be lost, so there must be none — or, with
        `save_first`, they are written out first (tick: its own work is done and stored before
        Jira is asked)."""
        if save_first:
            for name, data in zip(FILES, self._data()):
                self._write(name, data)
        elif self._dump() != self._taken:
            raise RuntimeError("the store was changed before releasing its lock")
        self.close()
        try:
            return work()
        finally:
            self._take()

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
            message = f"{name} 不是合法 JSON（{e}），已搬到 {bad.name}，改用預設"
            print(message, file=sys.stderr)
            self.warnings.append(message)
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
        for name, data in zip(FILES, self._data()):
            self._write(name, data)
        self.close()

    def close(self):
        """Release the lock without writing (after a failed action)."""
        if not self._lock.closed:
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
                                             "estimate": None, "doneAt": None, "notes": ""})

    def add_to_sprint(self, label, key):
        s = self.sprint(label)
        if s is not None and key not in s["keys"]:
            s["keys"].append(key)
        self.ticket(key)

    def set_sprint_keys(self, label, keys):
        """The sprint holds exactly these tickets (a resync that drops what Jira no longer lists)."""
        s = self.sprint(label)
        if s is not None:
            s["keys"] = list(dict.fromkeys(keys))

    def browse_url(self, key):
        return f"https://{self.config['site']}/browse/{key}"

    # ---------- bindings ----------

    def project_keys(self):
        return [p.strip().upper() for p in re.split(r"[,\s]+", self.config["projectKey"]) if p.strip()]

    def extract_keys(self, *texts):
        """Issue keys of the configured projects, in order of first appearance."""
        prefixes = tuple(p + "-" for p in self.project_keys())
        found = []
        for text in texts:
            for k in KEY_RE.findall((text or "").upper()):
                if k.startswith(prefixes) and k not in found:
                    found.append(k)
        return found

    def hours_per_point(self):
        try:
            return max(0.1, float(self.config.get("hoursPerPoint") or 8))
        except (TypeError, ValueError):
            return 8.0

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

def empty_review():
    return {"summary": "", "wentWell": [], "toImprove": [], "suggestions": [], "thanks": []}


def git_branch(cwd):
    if not cwd:
        return None
    try:
        r = subprocess.run(["/usr/bin/git", "-C", cwd, "rev-parse", "--abbrev-ref", "HEAD"],
                           capture_output=True, text=True, timeout=3)
    except (OSError, subprocess.SubprocessError):
        return None
    return r.stdout.strip() if r.returncode == 0 else None
