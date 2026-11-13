"""Batch 19: one ticket's same minutes count once, for records added from now on; old records
count exactly as they did; different tickets are never compared."""
import hashlib
import json
import tempfile
import unittest

import sprint  # noqa: F401  (loads the modules in the order the plugin does)
from store import Store

H = 3600.0
T0 = 1794470400.0


def old_records(store):
    """Overlaps of every kind, as the store held them before the `added` mark existed."""
    seg = store.segments
    seg["sessions"]["s1"] = {str(int(T0)): {"shares": {"PROJ-1": 100}, "end": T0 + 2 * H, "open": False, "name": "a"},
                             str(int(T0 + 5 * H)): {"shares": {"PROJ-1": 50, "PROJ-2": 50}, "end": T0 + 7 * H, "open": False, "name": "a"}}
    seg["sessions"]["s2"] = {str(int(T0 + H)): {"shares": {"PROJ-1": 100}, "end": T0 + 3 * H, "open": False, "name": "b"},
                             str(int(T0 + 6 * H)): {"shares": {"PROJ-1": 30, "PROJ-2": 70}, "end": T0 + 8 * H, "open": True, "name": "b"}}
    seg["manual"] += [
        {"id": "m1", "key": "PROJ-1", "start": T0 + 1.5 * H, "end": T0 + 4 * H, "kind": "開發", "note": "", "calendar": False},
        {"id": "m2", "key": "PROJ-1", "start": T0 + 3.5 * H, "end": T0 + 4.5 * H, "kind": "會議", "note": "", "calendar": False},
        {"id": "m3", "key": "PROJ-1", "start": T0 + 5.5 * H, "end": T0 + 6.5 * H, "kind": "開發", "note": "", "calendar": False,
         "session": "s1", "shares": {"PROJ-1": 60, "PROJ-2": 40}},
        {"id": "m4", "key": "PROJ-2", "start": T0 + 0.5 * H, "end": T0 + 1.5 * H, "kind": "討論", "note": "", "calendar": False},
        {"id": "m5", "key": None, "start": T0, "end": T0 + H, "kind": "支援", "note": "x", "calendar": False, "sprint": "S", "counted": True},
    ]


class DedupeTests(unittest.TestCase):
    def setUp(self):
        self.dir = tempfile.TemporaryDirectory()
        self.store = Store(self.dir.name)

    def tearDown(self):
        self.store.close()
        self.dir.cleanup()

    def session(self, sid, start, end, shares, added):
        self.store.segments["sessions"].setdefault(sid, {})[str(int(start))] = {"shares": shares, "end": end, "open": False, "name": sid, "added": added}

    def manual(self, key, start, hours, added, **more):
        m = self.store.add_manual(key, start, hours * 60, **{k: v for k, v in more.items() if k in ("kind", "note")})
        m.update(added=added, **{k: v for k, v in more.items() if k in ("session", "shares")})
        return m

    def total(self, key="PROJ-1", since=None, until=None):
        return self.store.hours_by_key(since, until).get(key, {}).get("total", 0.0) / H

    def test_old_records_count_exactly_as_before(self):
        old_records(self.store)
        out = {"all": self.store.hours_by_key(), "win": self.store.hours_by_key(T0 + 1.25 * H, T0 + 6.25 * H)}
        # The digest 0643880 gives for these records (computed before this batch changed hours.py).
        self.assertEqual(hashlib.sha256(json.dumps(out, sort_keys=True).encode()).hexdigest(),
                         "13b9e438412c1396d0b9569f5e726ad3b2ba377fccb3ec27804b78ff6730fbfa")
        # Old overlaps still count twice: s1 2 + 2×50%, s2 2 + 2×30%, m1 2.5, m2 1; m3 lies in s1's own stretch.
        self.assertAlmostEqual(self.total(), 2 + 1 + 2 + 0.6 + 2.5 + 1)

    def test_two_sessions_on_one_ticket_count_once_and_other_tickets_are_not_compared(self):
        self.session("a", T0, T0 + 2 * H, {"PROJ-1": 100}, 1)
        self.session("b", T0 + H, T0 + 3 * H, {"PROJ-1": 100}, 2)
        self.session("c", T0, T0 + 3 * H, {"PROJ-2": 100}, 3)
        self.assertEqual((self.total(), self.total("PROJ-2")), (3.0, 3.0))

    def test_manual_and_session_and_two_manual_entries(self):
        first = self.manual("PROJ-1", T0, 2, 1)
        self.session("a", T0 + H, T0 + 3 * H, {"PROJ-1": 100}, 2)
        second = self.manual("PROJ-1", T0 + 2.5 * H, 1, 3, kind="會議")
        b = self.store.hours_by_key()["PROJ-1"]
        self.assertEqual((b["total"], b["session"], b["manual"], b["meeting"]), (3.5 * H, 1 * H, 2.5 * H, 0.5 * H))
        seen = {e["id"]: (e["seconds"], e["overlap"]) for e in b["entries"]}
        self.assertEqual(seen, {first["id"]: (2 * H, 0.0), second["id"]: (0.5 * H, 0.5 * H)})
        self.assertEqual(sum(e["seconds"] for e in b["entries"]), b["manual"])
        self.assertEqual(b["kinds"], {"開發": 2 * H, "Session": 1 * H, "會議": 0.5 * H})

    def test_shares_on_one_ticket_add_up_to_a_whole_at_most(self):
        for shares, want in (((50, 50), 1.0), ((30, 30), 0.6), ((100, 50), 1.0), ((70, 60), 1.0)):
            self.store.segments["sessions"].clear()
            self.session("a", T0, T0 + H, {"PROJ-1": shares[0], "PROJ-2": 100 - shares[0]}, 1)
            self.session("b", T0, T0 + H, {"PROJ-1": shares[1], "PROJ-3": 100 - shares[1]}, 2)
            with self.subTest(shares=shares):
                self.assertAlmostEqual(self.total(), want)
                self.assertAlmostEqual(self.total("PROJ-2") + self.total("PROJ-3"), (100 - shares[0] + 100 - shares[1]) / 100)

    def test_a_booked_timer_and_its_own_session_still_count_once(self):
        self.session("s", T0, T0 + H, {"PROJ-1": 100}, 1)
        self.manual("PROJ-1", T0, 2, 2, session="s")
        self.assertEqual(self.total(), 2.0)

    def test_new_records_on_top_of_old_ones_add_only_what_is_not_counted(self):
        old_records(self.store)
        before = self.total()
        self.manual("PROJ-1", T0, 2, 5)                       # s1 and s2 already count these two hours (twice)
        self.manual("PROJ-1", T0 + 8 * H, 1, 6)                # nobody's there
        self.assertAlmostEqual(self.total(), before + 1)

    def test_a_window_gives_the_same_minutes_the_whole_does(self):
        self.manual("PROJ-1", T0, 2, 1)
        self.session("a", T0 + H, T0 + 3 * H, {"PROJ-1": 60, "PROJ-2": 40}, 2)
        self.manual("PROJ-1", T0 + 1.5 * H, 2, 3)
        cut = T0 + 1.75 * H
        self.assertAlmostEqual(self.total(None, None), self.total(None, cut) + self.total(cut, None))
        self.assertAlmostEqual(self.total(), 3.5)

    def test_the_mark_goes_on_new_records_only(self):
        old_records(self.store)
        self.store.record_segments({"id": "s2", "name": "b", "segments": [{"start": T0 + 6 * H, "end": T0 + 9 * H, "open": True},
                                                                          {"start": T0 + 10 * H, "end": T0 + 11 * H}]}, {"PROJ-1": 100})
        s2 = self.store.segments["sessions"]["s2"]
        self.assertNotIn("added", s2[str(int(T0 + 6 * H))])            # an old stretch growing stays old
        self.assertEqual(s2[str(int(T0 + 6 * H))]["end"], T0 + 9 * H)
        self.assertIn("added", s2[str(int(T0 + 10 * H))])
        self.assertIn("added", self.store.add_manual("PROJ-1", T0, 30))


if __name__ == "__main__":
    unittest.main()
