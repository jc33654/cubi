"""Work segments: what cubi reports per session, manual stretches, the seconds they add up to
per ticket, and what of it belongs on the calendar."""
import uuid

from review import MEETING_KINDS
from timers import MAX_ENTRY

SESSION_KIND = "Session"   # what session stretches are called next to manual kinds (a session may plan, then build)


class HoursMixin:
    """Store methods for `segments["sessions"]` and `segments["manual"]`."""

    def record_segments(self, session, shares):
        """Upsert the stretches cubi reports; the shares a stretch started with stay with it."""
        sess = self.segments["sessions"].setdefault(session["id"], {})
        for seg in session.get("segments") or []:
            entry = sess.setdefault(str(int(seg["start"])), {"shares": shares})
            entry["end"] = seg["end"]
            entry["open"] = bool(seg.get("open"))
            entry["name"] = session.get("name", "")
            if not entry.get("shares"):
                entry["shares"] = shares

    def add_manual(self, key, start, minutes, kind="開發", note="", calendar=False, sprint=None, counted=True):
        """One stretch of work cubi did not see. A timer's entry also carries `shares` (split over
        several tickets, `key` the first) and `session` (its own stretches over the same minutes
        are not counted twice). Work with no ticket has `key` None and belongs to `sprint`;
        `counted` says whether it adds to the sprint's hours."""
        try:
            start, minutes = float(start), float(minutes)
        except (TypeError, ValueError):
            raise ValueError("開始時間與長度要是數字")
        if not (1 <= minutes <= MAX_ENTRY / 60) or start != start:
            raise ValueError("長度要在 1 分鐘到 24 小時之間")
        entry = {"id": uuid.uuid4().hex[:12], "key": key, "start": start, "end": start + minutes * 60,
                 "kind": kind, "note": note, "calendar": bool(calendar)}
        if key is None:
            entry.update(sprint=sprint, counted=bool(counted))
        self.segments["manual"].append(entry)
        return entry

    def remove_manual(self, entry_id):
        before = len(self.segments["manual"])
        self.segments["manual"] = [m for m in self.segments["manual"] if m["id"] != entry_id]
        return len(self.segments["manual"]) < before

    def _timer_extra(self, m, since, until):
        """A booked timer's seconds in [since, until] that its own session's stretches do not
        already cover (those minutes are counted as the stretches)."""
        own = self.segments["sessions"].get(m.get("session") or "", {})
        secs = overlap(m["start"], m["end"], since, until)
        secs -= sum(overlap(max(m["start"], float(st)), min(m["end"], seg["end"]), since, until) for st, seg in own.items())
        return max(0.0, secs)

    def session_seconds(self, sid, since=None, until=None, key=None):
        """This session's own work in [since, until]: its stretches plus its booked timers, each
        minute once. With `key`, only that ticket's share of it."""
        def part(shares):
            return 1.0 if key is None else (shares or {}).get(key, 0) / 100
        own = self.segments["sessions"].get(sid, {})
        secs = sum(overlap(float(start), seg["end"], since, until) * part(seg.get("shares")) for start, seg in own.items())
        for m in self.segments["manual"]:
            if m.get("session") == sid:
                secs += self._timer_extra(m, since, until) * part(m.get("shares") or {m["key"]: 100})
        return secs

    def active_in(self, sid, since, until):
        """Whether the session worked (stretches or booked timers) in [since, until] (None:
        open-ended), or is timing now."""
        return sid in self.segments["timers"] or self.session_seconds(sid, since, until) > 0

    def other_work(self, label):
        """The sprint's work that has no ticket."""
        return [m for m in self.segments["manual"] if m.get("key") is None and m.get("sprint") == label]

    def hours_by_key(self, since=None, until=None):
        """Seconds per key within [since, until]: session stretches split by their shares, manual
        entries whole. 'meeting' is the part of 'manual' whose kind is a meeting or discussion;
        'kinds' is the same seconds by kind, session stretches as SESSION_KIND; 'entries' lists the
        manual entries in the window with the seconds each one adds here (so they sum to 'manual')."""
        out = {}

        def bucket(key):
            return out.setdefault(key, {"session": 0.0, "manual": 0.0, "meeting": 0.0, "kinds": {}, "entries": []})

        def add(b, kind, secs):
            b["kinds"][kind] = b["kinds"].get(kind, 0.0) + secs

        for sess in self.segments["sessions"].values():
            for start, seg in sess.items():
                secs = overlap(float(start), seg["end"], since, until)
                for key, pct in (seg.get("shares") or {}).items():
                    bucket(key)["session"] += secs * pct / 100
                    add(bucket(key), SESSION_KIND, secs * pct / 100)
        for m in self.segments["manual"]:
            if m.get("key") is None:
                continue
            if not overlap(m["start"], m["end"], since, until):
                continue
            secs = self._timer_extra(m, since, until)
            for key, pct in (m.get("shares") or {m["key"]: 100}).items():
                part = secs * pct / 100
                bucket(key)["entries"].append({"id": m["id"], "start": m["start"], "kind": m.get("kind") or "其他",
                                               "note": m.get("note") or m.get("reason") or "", "pct": pct, "seconds": part,
                                               "session": bool(m.get("session"))})
                bucket(key)["manual"] += part
                add(bucket(key), m.get("kind") or "其他", part)
                if m.get("kind") in MEETING_KINDS:
                    bucket(key)["meeting"] += part
        for b in out.values():
            b["total"] = b["session"] + b["manual"]
        return out

    def calendar_entries(self, now, window=48 * 3600):
        """What cubi should have on the calendar: finished stretches with keys, and manual entries
        flagged for it, from the last `window` seconds. Re-sent every tick; cubi dedupes."""
        entries = []
        for m in self.segments["manual"]:
            if m.get("calendar") and m["end"] >= now - window and 60 <= m["end"] - m["start"] <= MAX_ENTRY:
                keys = list(m.get("shares") or ([m["key"]] if m.get("key") else []))
                entries.append({
                    "title": f"{' '.join(keys)} {m.get('note') or ''}（{m.get('kind', '')}）".replace("  ", " ").strip(),
                    "start": m["start"], "end": m["end"],
                    "notes": "\n".join(([m["reason"]] if m.get("reason") else []) + [self.browse_url(k) for k in keys]),
                    "marker": f"sprint:manual:{m['id']}",
                })
        for sid, sess in self.segments["sessions"].items():
            # Minutes a timer from this same session covers are on its event already, or will be
            # once it stops: send only the pieces outside it (a piece keeps a stable marker: its start).
            timers = [(m["start"], m["end"]) for m in self.segments["manual"] if m.get("session") == sid]
            if sid in self.segments["timers"]:
                t = self.segments["timers"][sid]
                timers.append((t["start"], self.timer_end(t, now)))
            for start, seg in sess.items():
                keys = list((seg.get("shares") or {}).keys())
                length = seg["end"] - float(start)
                if seg.get("open") or not keys or seg["end"] < now - window or not 60 <= length <= MAX_ENTRY:
                    continue
                # The session name often starts with the keys themselves; say each once.
                name = " ".join(w for w in (seg.get("name") or "").split() if w.upper() not in keys)
                for lo, hi in subtract((float(start), seg["end"]), timers):
                    if hi - lo < 60:
                        continue
                    entries.append({
                        "title": " ".join(keys) + (" " + name if name else ""),
                        "start": lo, "end": hi,
                        "notes": "\n".join(self.browse_url(k) for k in keys),
                        "marker": f"sprint:{sid[:8]}:{int(lo)}",
                    })
        # Newest first, manual entries ahead of stretches, so a busy week never starves a fresh meeting.
        entries.sort(key=lambda e: (not e["marker"].startswith("sprint:manual:"), -e["start"]))
        return entries[:50]


def subtract(span, cuts):
    """`span` (start, end) minus every (start, end) in `cuts`, as the pieces left over."""
    pieces = [span]
    for c0, c1 in cuts:
        pieces = [p for lo, hi in pieces for p in ((lo, min(hi, c0)), (max(lo, c1), hi)) if p[1] > p[0]]
    return pieces


def overlap(start, end, since, until):
    lo = start if since is None else max(start, since)
    hi = end if until is None else min(end, until)
    return max(0.0, hi - lo)
