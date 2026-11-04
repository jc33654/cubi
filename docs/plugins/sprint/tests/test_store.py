import tempfile
import unittest
from datetime import datetime

from store import Store


def session(sid="s1", name="PROJ-12 範例工單", cwd="/tmp", segments=()):
    return {"id": sid, "name": name, "cwd": cwd, "agent": "claude-code", "segments": list(segments)}


class StoreTests(unittest.TestCase):
    def setUp(self):
        self.dir = tempfile.TemporaryDirectory()
        self.store = Store(self.dir.name)
        self.store.config["projectKey"] = "PROJ"
        self.store.config["site"] = "jira.example"

    def tearDown(self):
        self.store.save()   # releases the directory lock
        self.dir.cleanup()

    def test_extracts_project_keys_once_in_order(self):
        keys = self.store.extract_keys("PROJ-12 與 proj-7 一起做", "feature/PROJ-12-login", "/Users/me/OTHER-3")
        self.assertEqual(keys, ["PROJ-12", "PROJ-7"])

    def test_binding_merges_auto_manual_and_removed(self):
        rec = self.store.binding(session(name="PROJ-12 PROJ-13"))
        self.assertEqual(self.store.bound_keys(rec), ["PROJ-12", "PROJ-13"])
        self.store.unbind("s1", "PROJ-13")          # an auto key: remembered as removed
        self.store.bind("s1", "PROJ-20")            # a manual key
        rec = self.store.binding(session(name="PROJ-12 PROJ-13"))
        self.assertEqual(self.store.bound_keys(rec), ["PROJ-12", "PROJ-20"])
        self.store.bind("s1", "PROJ-13")            # bound again by hand: no longer removed
        self.assertEqual(self.store.bound_keys(self.store.binding(session(name="PROJ-12 PROJ-13"))), ["PROJ-12", "PROJ-13", "PROJ-20"])

    def test_shares_default_to_equal_parts(self):
        rec = self.store.binding(session(name="PROJ-1 PROJ-2 PROJ-3"))
        self.assertEqual(self.store.shares(rec), {"PROJ-1": 33.33, "PROJ-2": 33.33, "PROJ-3": 33.33})
        self.store.set_shares("s1", {"PROJ-1": 70, "PROJ-2": 30, "PROJ-3": 0})
        # Not every key covered (PROJ-3 is 0): back to equal parts rather than a lopsided split.
        self.assertEqual(self.store.shares(self.store.binding(session(name="PROJ-1 PROJ-2 PROJ-3"))), {"PROJ-1": 33.33, "PROJ-2": 33.33, "PROJ-3": 33.33})
        self.store.set_shares("s1", {"PROJ-1": 70, "PROJ-2": 20, "PROJ-3": 10})
        self.assertEqual(self.store.shares(self.store.binding(session(name="PROJ-1 PROJ-2 PROJ-3"))), {"PROJ-1": 70.0, "PROJ-2": 20.0, "PROJ-3": 10.0})

    def test_hours_split_by_shares_and_manual_entries_count_whole(self):
        s = session(name="PROJ-1 PROJ-2", segments=[{"start": 1000, "end": 4600, "open": False}, {"start": 5000, "end": 5300, "open": True}])
        rec = self.store.binding(s)
        self.store.record_segments(s, self.store.shares(rec))
        self.store.add_manual("PROJ-1", 9000, 60, kind="會議", note="需求討論", calendar=True)
        hours = self.store.hours_by_key()
        self.assertAlmostEqual(hours["PROJ-1"]["session"], 3900 * 0.5, places=0)
        self.assertAlmostEqual(hours["PROJ-2"]["session"], 3900 * 0.5, places=0)
        self.assertEqual(hours["PROJ-1"]["manual"], 3600)
        self.assertEqual(hours["PROJ-1"]["meeting"], 3600)
        self.assertAlmostEqual(hours["PROJ-1"]["total"], 1950 + 3600, places=0)
        # A window cuts the stretches, not the entries' existence.
        self.assertAlmostEqual(self.store.hours_by_key(since=2800, until=4600)["PROJ-1"]["session"], 900, places=0)

    def test_open_stretch_grows_and_keeps_its_first_shares(self):
        s = session(name="PROJ-1", segments=[{"start": 100, "end": 200, "open": True}])
        self.store.record_segments(s, {"PROJ-1": 100.0})
        s2 = session(name="PROJ-1 PROJ-2", segments=[{"start": 100, "end": 900, "open": True}])
        self.store.record_segments(s2, {"PROJ-1": 50.0, "PROJ-2": 50.0})
        seg = self.store.segments["sessions"]["s1"]["100"]
        self.assertEqual((seg["end"], seg["shares"]), (900, {"PROJ-1": 100.0}))
        self.store.set_shares("s1", {"PROJ-1": 50, "PROJ-2": 50}, since=0)   # apply to the sprint: rewrites
        self.assertEqual(self.store.segments["sessions"]["s1"]["100"]["shares"], {})  # s1 now has no binding record keys → empty
        self.store.bind("s1", "PROJ-1")
        self.store.bind("s1", "PROJ-2")
        self.store.set_shares("s1", {"PROJ-1": 50, "PROJ-2": 50}, since=0)
        self.assertEqual(self.store.segments["sessions"]["s1"]["100"]["shares"], {"PROJ-1": 50.0, "PROJ-2": 50.0})

    def test_calendar_entries_skip_open_short_old_and_unbound(self):
        now = 100_000.0
        s = session(name="PROJ-1 登入", segments=[
            {"start": 90_000, "end": 93_600, "open": False},     # good
            {"start": 94_000, "end": 94_030, "open": False},     # 30 s: too short
            {"start": 95_000, "end": 99_000, "open": True},      # still running
            {"start": 1_000, "end": 2_000, "open": False},       # too old
        ])
        self.store.record_segments(s, self.store.shares(self.store.binding(s)))
        unbound = session(sid="s2", name="沒單號", segments=[{"start": 90_000, "end": 93_600, "open": False}])
        self.store.record_segments(unbound, {})
        self.store.add_manual("PROJ-1", 96_000, 30, kind="會議", note="站會", calendar=True)
        self.store.add_manual("PROJ-1", 97_000, 30, kind="開發", note="", calendar=False)
        entries = self.store.calendar_entries(now, window=10_000)
        # Manual entries first, then stretches newest first; the name does not repeat the key.
        self.assertEqual([e["marker"] for e in entries], [f"sprint:manual:{self.store.segments['manual'][0]['id']}", "sprint:s1:90000"])
        self.assertEqual(entries[0]["title"], "PROJ-1 站會（會議）")
        self.assertEqual(entries[1]["title"], "PROJ-1 登入")
        self.assertEqual(entries[1]["notes"], "https://jira.example/browse/PROJ-1")

    def test_manual_entries_are_validated(self):
        with self.assertRaises(ValueError):
            self.store.add_manual("PROJ-1", 1000, 0)
        with self.assertRaises(ValueError):
            self.store.add_manual("PROJ-1", 1000, 25 * 60)
        with self.assertRaises(ValueError):
            self.store.add_manual("PROJ-1", 1000, None)
        with self.assertRaises(ValueError):
            self.store.new_sprint("../x")
        self.assertEqual(self.store.add_manual("PROJ-1", 1000, "90")["end"], 1000 + 90 * 60)

    def test_lower_case_project_key_still_binds(self):
        self.store.config["projectKey"] = "proj"
        self.assertEqual(self.store.extract_keys("proj-3 與 PROJ-4"), ["PROJ-3", "PROJ-4"])

    def test_broken_file_is_set_aside_not_overwritten(self):
        self.store.save()
        with open(self.store.root / "tickets.json", "w") as f:
            f.write("{not json")
        again = Store(self.dir.name)
        self.assertEqual(again.tickets, {})
        self.assertTrue(any(p.name.startswith("tickets.json.bad-") for p in again.root.iterdir()))
        again.save()
        self.assertTrue(any(p.name.startswith("tickets.json.bad-") for p in again.root.iterdir()))

    def test_save_and_reload_round_trip(self):
        self.store.new_sprint("Sprint7", "Sprint 7", "2026-11-03", "2026-11-14", "目標")
        self.store.add_to_sprint("Sprint7", "PROJ-1")
        self.store.ticket("PROJ-1")["actual"] = 2.5
        self.store.save()
        again = Store(self.dir.name)
        self.assertEqual(again.sprints["current"], "Sprint7")
        self.assertEqual(again.sprint("Sprint7")["keys"], ["PROJ-1"])
        self.assertEqual(again.tickets["PROJ-1"]["actual"], 2.5)
        self.assertEqual(again.config["site"], "jira.example")


if __name__ == "__main__":
    unittest.main()
