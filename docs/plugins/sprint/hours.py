"""Work segments: what cubi reports per session, manual stretches, the seconds they add up to
per ticket, and what of it belongs on the calendar."""
import time
import uuid

from review import MEETING_KINDS, sprint_range
from timers import MAX_ENTRY, manual_title

SESSION_KIND = "Session"   # what session stretches are called next to manual kinds (a session may plan, then build)


class HoursMixin:
    """Store methods for `segments["sessions"]` and `segments["manual"]`."""

    def record_segments(self, session, shares, item=None):
        """Upsert the stretches cubi reports; the shares (or the work item, `item` = {item,
        counted}) a stretch started with stay with it. A stretch first seen now is marked `added`
        (see hours_by_key). A stretch marked running that this report does not have at all
        ended while cubi was not looking (it quit or restarted, or the stretch was too short for cubi
        to keep): it is marked ended, and `lost`: where it really ended is unknown, so it never goes
        on the calendar (it never could while it was marked running)."""
        sess = self.segments["sessions"].setdefault(session["id"], {})
        if "segments" in session:
            seen = {str(int(seg["start"])) for seg in session["segments"] or []}
            for start, entry in sess.items():
                if entry.get("open") and start not in seen:
                    entry.update(open=False, lost=True)
        for seg in session.get("segments") or []:
            entry = sess.setdefault(str(int(seg["start"])), {"shares": shares, "added": time.time(), **(item or {})})
            entry["end"] = seg["end"]
            entry["open"] = bool(seg.get("open"))
            entry.pop("lost", None)
            entry["name"] = session.get("name", "")
            if not entry.get("shares") and not entry.get("item") and not entry.get("itemDeleted"):
                entry["shares"] = shares
                if item and not shares:
                    entry.update(item)

    def add_manual(self, key, start, minutes, kind="開發", note="", calendar=False, sprint=None, counted=True, item=None):
        """One stretch of work cubi did not see. A timer's entry also carries `shares` (split over
        several tickets, `key` the first) and `session`. Work with no ticket has `key` None and
        belongs to `sprint`; `counted` says whether it adds to the sprint's hours; a work item's
        timer also names its `item`.

        Marked `overSession`: its minutes are taken out of every session's own stretches (any
        ticket, or none), so they count once, as this record. Records written before the mark
        leave the stretches as they were."""
        try:
            start = float(start)
        except (TypeError, ValueError):
            raise ValueError("開始時間與長度要是數字")
        minutes = check_minutes(minutes)
        if start != start:
            raise ValueError("開始時間與長度要是數字")
        entry = {"id": uuid.uuid4().hex[:12], "key": key, "start": start, "end": start + minutes * 60,
                 "kind": kind, "note": note, "calendar": bool(calendar), "added": time.time(), "overSession": True}
        if key is None:
            entry.update(sprint=sprint, counted=bool(counted))
        if item:
            entry["item"] = item
        self.segments["manual"].append(entry)
        return entry

    def remove_manual(self, entry_id):
        before = len(self.segments["manual"])
        self.segments["manual"] = [m for m in self.segments["manual"] if m["id"] != entry_id]
        return len(self.segments["manual"]) < before

    def manual_cuts(self):
        """The spans session stretches give way to (see add_manual)."""
        return [(m["start"], m["end"]) for m in self.segments["manual"] if m.get("overSession")]

    @staticmethod
    def session_pieces(start, end, cuts):
        """A session stretch without the minutes a manual record covers."""
        return subtract((start, end), [c for c in cuts if c[1] > start and c[0] < end])

    def _timer_extra(self, m, since, until):
        """A booked timer's seconds in [since, until] that its own session's stretches do not
        already cover (those minutes are counted as the stretches). One marked `overSession`
        counts whole: the stretches give way to it."""
        if m.get("overSession"):
            return overlap(m["start"], m["end"], since, until)
        own = self.segments["sessions"].get(m.get("session") or "", {})
        secs = overlap(m["start"], m["end"], since, until)
        secs -= sum(overlap(max(m["start"], float(st)), min(m["end"], seg["end"]), since, until) for st, seg in own.items())
        return max(0.0, secs)

    def _timer_pieces(self, m):
        """A manual entry's time as pieces; a booked timer's without its own session's stretches."""
        if m.get("overSession"):
            return [(m["start"], m["end"])]
        own = self.segments["sessions"].get(m.get("session") or "", {}) if m.get("session") else {}
        return subtract((m["start"], m["end"]), [(float(st), seg["end"]) for st, seg in own.items()])

    def _add_fresh(self, fresh, since, until, bucket, add, cuts):
        """hours_by_key's marked records: each adds, per ticket, only what the ticket's time does
        not already fill (see `take`), the unmarked records counted first."""
        cover = {}
        for sess in self.segments["sessions"].values():
            for start, seg in sess.items():
                if "added" not in seg:
                    for key, pct in (seg.get("shares") or {}).items():
                        cover.setdefault(key, []).extend(clip(self.session_pieces(float(start), seg["end"], cuts), since, until, pct))
        for m in self.segments["manual"]:
            if m.get("key") is not None and "added" not in m:
                for key, pct in (m.get("shares") or {m["key"]: 100}).items():
                    cover.setdefault(key, []).extend(clip(self._timer_pieces(m), since, until, pct))
        for _, _, _, m, pieces, shares in sorted(fresh, key=lambda f: f[:3]):
            for key, pct in shares.items():
                spans = clip(pieces, since, until, pct)
                got = sum(take(cover.setdefault(key, []), lo, hi, rate) for lo, hi, rate in spans)
                b = bucket(key)
                if m is None:
                    b["session"] += got
                    add(b, SESSION_KIND, got)
                    continue
                whole = sum((hi - lo) * rate for lo, hi, rate in spans)
                b["entries"].append({"id": m["id"], "start": m["start"], "kind": m.get("kind") or "其他",
                                     "note": m.get("note") or m.get("reason") or "", "pct": pct, "seconds": got,
                                     "session": bool(m.get("session")), "overlap": whole - got})
                b["manual"] += got
                add(b, m.get("kind") or "其他", got)
                if m.get("kind") in MEETING_KINDS:
                    b["meeting"] += got

    def session_seconds(self, sid, since=None, until=None, key=None):
        """This session's own work in [since, until]: its stretches plus its booked timers, each
        minute once. With `key`, only that ticket's share of it."""
        def part(shares):
            return 1.0 if key is None else (shares or {}).get(key, 0) / 100
        own, cuts = self.segments["sessions"].get(sid, {}), self.manual_cuts()
        secs = sum(overlap(lo, hi, since, until) * part(seg.get("shares"))
                   for start, seg in own.items() for lo, hi in self.session_pieces(float(start), seg["end"], cuts))
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
        return [m for m in self.segments["manual"] if m.get("key") is None and self.sprint_of(m) == label]

    def sprint_of(self, entry):
        """The sprint a stretch with no ticket counts in: the one whose days hold its start, read
        from the dates as they are now (a sprint made afterwards gets what fell in its days); the
        label noted when it was written only where no sprint holds that time."""
        for s in sorted(self.sprints["sprints"].values(), key=lambda s: (s.get("start") or "", s["label"])):
            since, until = sprint_range(s)
            if since is not None and until is not None and since <= entry["start"] < until:
                return s["label"]
        return entry.get("sprint")

    def hours_by_key(self, since=None, until=None):
        """Seconds per key within [since, until]: session stretches split by their shares, manual
        entries whole. 'meeting' is the part of 'manual' whose kind is a meeting or discussion;
        'kinds' is the same seconds by kind, session stretches as SESSION_KIND; 'entries' lists the
        manual entries in the window with the seconds each one adds here (so they sum to 'manual').

        A record marked `added` (written since that mark exists) counts only the time its ticket is
        not already counted at: per ticket and moment, the shares of everything there add up to
        100% at most, records in the order they were added. Different tickets are never compared.
        Unmarked records count as they always did, in the same order, so old numbers stay exactly
        as they were. Session stretches leave out what a manual record marked `overSession` covers,
        whatever its ticket (see add_manual)."""
        out, fresh, cuts = {}, [], self.manual_cuts()

        def bucket(key):
            return out.setdefault(key, {"session": 0.0, "manual": 0.0, "meeting": 0.0, "kinds": {}, "entries": []})

        def add(b, kind, secs):
            b["kinds"][kind] = b["kinds"].get(kind, 0.0) + secs

        for sid, sess in self.segments["sessions"].items():
            for start, seg in sess.items():
                pieces = self.session_pieces(float(start), seg["end"], cuts)
                if "added" in seg:
                    fresh.append((seg["added"], sid, float(start), None, pieces, seg.get("shares") or {}))
                    continue
                secs = sum(overlap(lo, hi, since, until) for lo, hi in pieces)
                for key, pct in (seg.get("shares") or {}).items():
                    bucket(key)["session"] += secs * pct / 100
                    add(bucket(key), SESSION_KIND, secs * pct / 100)
        for m in self.segments["manual"]:
            if m.get("key") is None:
                continue
            if not overlap(m["start"], m["end"], since, until):
                continue
            if "added" in m:
                fresh.append((m["added"], m["id"], m["start"], m, self._timer_pieces(m), m.get("shares") or {m["key"]: 100}))
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
        if fresh:
            self._add_fresh(fresh, since, until, bucket, add, cuts)
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
                    "title": manual_title(m),
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
                if seg.get("open") or seg.get("lost") or not keys or seg["end"] < now - window or not 60 <= length <= MAX_ENTRY:
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


def check_minutes(minutes):
    """A stretch's length in minutes as a number, or ValueError saying what it must be."""
    try:
        minutes = float("x" if isinstance(minutes, bool) else minutes)   # true is not one minute
    except (TypeError, ValueError):
        raise ValueError("開始時間與長度要是數字")
    if not 1 <= minutes <= MAX_ENTRY / 60:   # nan fails the comparison too
        raise ValueError("長度要在 1 分鐘到 24 小時之間")
    return minutes


def subtract(span, cuts):
    """`span` (start, end) minus every (start, end) in `cuts`, as the pieces left over."""
    pieces = [span]
    for c0, c1 in cuts:
        pieces = [p for lo, hi in pieces for p in ((lo, min(hi, c0)), (max(lo, c1), hi)) if p[1] > p[0]]
    return pieces


def clip(pieces, since, until, pct):
    """(start, end) pieces cut to [since, until], each with its share as a rate (1.0 = 100%)."""
    return [(lo, hi, pct / 100) for lo, hi in ((max(a, since) if since is not None else a, min(b, until) if until is not None else b)
                                                for a, b in pieces) if hi > lo]


def take(cover, lo, hi, rate):
    """The seconds of [lo, hi) at `rate` that the ticket's time there does not already fill
    (`cover`: (start, end, rate) already counted; at most 1.0 in all at any moment). What is taken
    joins `cover`."""
    cuts = sorted({lo, hi} | {x for s, e, _ in cover for x in (s, e) if lo < x < hi})
    got, taken = 0.0, []
    for a, b in zip(cuts, cuts[1:]):
        full = sum(r for s, e, r in cover if s <= a and b <= e)
        r = min(rate, 1.0 - full)
        if r > 1e-9:
            got += (b - a) * r
            taken.append((a, b, r))
    cover.extend(taken)
    return got


def overlap(start, end, since, until):
    lo = start if since is None else max(start, since)
    hi = end if until is None else min(end, until)
    return max(0.0, hi - lo)
