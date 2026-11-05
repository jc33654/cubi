"""Manual timers started from a session's card: start, stop (booked as one manual stretch),
and the ones whose session went away."""

MAX_ENTRY = 24 * 3600
TIMER_KIND = "計時"
# A timer whose session cubi has not reported for this long is stopped (the session ended or was
# let go, so its card and ⏸ button are gone). Long enough to ride out a cubi restart.
ORPHAN_AFTER = 15 * 60


class TimerMixin:
    """Store methods for `segments["timers"]` (session id → {start, shares, seen})."""


    def timer(self, sid):
        return self.segments["timers"].get(sid)

    def timer_start(self, sid, shares, now):
        if not shares:
            raise ValueError("這個 session 還沒綁單，先綁單再計時")
        if sid not in self.segments["timers"]:
            self.segments["timers"][sid] = {"start": float(now), "shares": shares, "seen": float(now)}
        return self.segments["timers"][sid]

    def timer_stop(self, sid, now, reason=""):
        """Ends the timer and books it as one manual stretch. Over 24 h (forgotten overnight) it is
        cut at 24 h; under a minute it is dropped. Returns (entry or None, note)."""
        t = self.segments["timers"].pop(sid, None)
        if t is None:
            return None, "沒有在計時"
        end = min(float(now), t["start"] + MAX_ENTRY)
        note = "超過 24 小時，只記 24 小時" if now - t["start"] > MAX_ENTRY else ""
        minutes = (end - t["start"]) / 60
        if minutes < 1:
            return None, "不到 1 分鐘，沒有記"
        entry = self.add_manual(next(iter(t["shares"])), t["start"], minutes, TIMER_KIND, "", True)
        entry.update(shares=t["shares"], session=sid, reason=reason or note)
        return entry, note

    def stop_orphan_timers(self, live_ids, now, still_open=frozenset()):
        """Timers whose session cubi stopped reporting: stopped at the session's last activity.
        `still_open` are the sessions Claude Code itself still lists: after a cubi restart an idle
        session (say, during the very meeting being timed) is not reported until its next event."""
        stopped = []
        for sid, t in list(self.segments["timers"].items()):
            if sid in live_ids or sid in still_open:
                t["seen"] = float(now)
                continue
            if now - t.get("seen", t["start"]) < ORPHAN_AFTER:
                continue
            # The last time anyone could still have been working: the session's last stretch, or the
            # last tick that saw it (a meeting with the session idle but open counts).
            ends = [seg["end"] for seg in self.segments["sessions"].get(sid, {}).values()]
            last = max([t.get("seen", t["start"])] + [e for e in ends if e > t["start"]])
            entry, _ = self.timer_stop(sid, last, "session 結束，自動停止")
            stopped.append((sid, entry))
        return stopped
