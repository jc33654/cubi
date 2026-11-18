"""Batch 40: every record with no ticket is under a work item. A work item is a ticket without a
Jira key: its time is what its sessions write plus the records under it, and whether that counts
in the sprint is the item's, not each record's. Records from before (under none) stay as they were."""
import unittest
from datetime import datetime

import worklog
from tests.test_items import Base, H, T0

at = lambda ts: datetime.fromtimestamp(ts).isoformat(timespec="minutes")   # noqa: E731


class RecordsUnderItemsTests(Base):
    def add(self, start, minutes=60, **p):
        return worklog.time_add(self.store, {"key": "", "start": at(start), "minutes": minutes, "kind": "會議", **p})

    def test_a_record_with_no_ticket_needs_an_item(self):
        for p, said in (({}, "補記要掛在一個工作底下"), ({"item": "  "}, "補記要掛在一個工作底下"),
                        ({"item": "雜事"}, "沒有「雜事」這個工作項目"), ({"item": "雜事", "newItem": "false"}, "沒有「雜事」這個工作項目"),
                        ({"item": "PROJ-1 會議", "newItem": True}, "看起來像單號")):
            with self.assertRaises(ValueError) as e:
                self.add(T0, **p)
            self.assertIn(said, str(e.exception))
        self.assertEqual((self.store.segments["manual"], self.store.sprints.get("items", {})), ([], {}))

    def test_a_new_item_is_made_with_its_first_record_and_its_own_setting(self):
        self.add(T0, item=" 事故  處理 ", newItem=True, itemCounted=True, note="")
        self.add(T0 + H, item="面試", newItem=True)
        self.assertEqual(self.store.sprints["items"], {"事故 處理": {"counted": True}, "面試": {"counted": False}})
        self.assertEqual([(m["item"], m["counted"], m["note"]) for m in self.store.segments["manual"]], [("事故 處理", True, ""), ("面試", False, "")])
        self.assertEqual(self.sprint_seconds(), 1.0)
        with self.assertRaises(ValueError) as e:
            self.add(T0 + 2 * H, item="面試", newItem=True)                                # there already: its own ＋
        self.assertIn("已有「面試」：要補記請按它那一列的＋", str(e.exception))
        with self.assertRaises(ValueError):
            self.add(T0 + 2 * H, minutes=0, item="新的", newItem=True)                       # refused: no item left behind
        self.assertNotIn("新的", self.store.sprints["items"])

    def test_a_record_follows_its_item_and_so_does_its_item_time(self):
        self.bind("s1", "小工具開發")
        self.report("s1", [(T0, T0 + H, False)])
        self.add(T0 + 2 * H, item="小工具開發", note="code review")
        self.assertEqual(self.sprint_seconds(), 0.0)                                       # the item is not counted
        out = worklog.item_update(self.store, {"name": "小工具開發", "counted": True, "now": T0 + 3 * H})
        self.assertEqual(out["itemChanged"]["seconds"], 2 * H)                             # automatic + the record
        self.assertEqual(self.sprint_seconds(), 2.0)
        self.add(T0 + 4 * H, item="小工具開發")
        self.assertTrue(self.store.segments["manual"][-1]["counted"])

    def test_a_record_over_its_own_items_session_is_not_said_to_cut_it(self):
        self.bind("s1", "小工具開發")
        self.report("s1", [(T0, T0 + 2 * H, False)], {})
        added = self.add(T0 + H, 30, item="小工具開發")["added"]
        self.assertEqual(added["cut"], [])
        self.bind("s2", "雜事")
        self.report("s2", [(T0 + 4 * H, T0 + 6 * H, False)], {})
        self.assertEqual(self.add(T0 + 5 * H, 30, item="小工具開發")["added"]["cut"], [{"item": "雜事", "seconds": 0.5 * H, "counted": False, "inSprint": False}])

    def test_what_the_records_own_ticket_or_item_already_had_is_said(self):
        # Batch 42 (F42-1): never listed as given way, so said apart: the hours grow by less than the record.
        self.report("s1", [(T0, T0 + H, False)], {"PROJ-1": 100})
        before = self.sprint_seconds()
        added = worklog.time_add(self.store, {"key": "PROJ-1", "start": at(T0 + 0.5 * H), "minutes": 60})["added"]
        self.assertEqual((added["cut"], added["own"]), ([], 0.5 * H))
        self.assertAlmostEqual(self.sprint_seconds() - before, 0.5)
        self.bind("s2", "會議")
        worklog.item_update(self.store, {"name": "會議", "counted": True, "now": T0})
        self.report("s2", [(T0 + 3 * H, T0 + 5 * H, False)], {})
        before = self.sprint_seconds()
        added = self.add(T0 + 4 * H, 30, item="會議")["added"]
        self.assertEqual((added["cut"], added["own"]), ([], 0.5 * H))
        self.assertAlmostEqual(self.sprint_seconds(), before)
        self.assertEqual(self.add(T0 + 8 * H, 30, item="會議")["added"]["own"], 0)                # over no session
        # Over an earlier record of the same ticket (F42-2): that one's, not a session's. (Records of
        # an item are not one time counted once: each counts whole.)
        worklog.time_add(self.store, {"key": "PROJ-1", "start": at(T0 + 10 * H), "minutes": 60})
        self.assertEqual(worklog.time_add(self.store, {"key": "PROJ-1", "start": at(T0 + 10.5 * H), "minutes": 60})["added"]["own"], 0.5 * H)
        self.assertEqual(self.add(T0 + 8 * H + 15 * 60, 30, item="會議")["added"]["own"], 0)

    def test_what_gave_way_says_whether_the_sprints_hours_went_down_with_it(self):
        self.report("s2", [(T0, T0 + 2 * H, False)], {"PROJ-1": 50, "OPS-9": 50})          # OPS-9: not one of Sprint7's
        self.bind("s3", "會議")
        worklog.item_update(self.store, {"name": "會議", "counted": True, "now": T0})
        self.report("s3", [(T0, T0 + 2 * H, False)], {})
        self.bind("s4", "雜事")
        self.report("s4", [(T0, T0 + 2 * H, False)], {})
        self.store.add_item("支援", True)
        added = self.add(T0 + H, 30, item="支援")["added"]
        self.assertEqual(sorted(added["cut"], key=str), sorted([
            {"key": "OPS-9", "seconds": 0.25 * H, "inSprint": False}, {"key": "PROJ-1", "seconds": 0.25 * H, "inSprint": True},
            {"item": "會議", "seconds": 0.5 * H, "counted": True, "inSprint": True}, {"item": "雜事", "seconds": 0.5 * H, "counted": False, "inSprint": False}], key=str))
        self.assertFalse(added["cutMinor"])
        with_it = self.sprint_seconds()
        worklog.time_remove(self.store, {"id": self.store.segments["manual"][-1]["id"]})
        # Without it: back the minutes PROJ-1 and 會議 gave way, less the counted record itself.
        self.assertAlmostEqual(self.sprint_seconds() - with_it, 0.25 + 0.5 - 0.5)

    def test_minutes_taken_across_two_sprints_are_said_where_they_were(self):
        self.store.new_sprint("Sprint8", "", "2026-11-28", "2026-12-11")
        self.store.sprints["current"] = "Sprint7"
        self.store.add_to_sprint("Sprint8", "PROJ-1")
        late = datetime(2026, 11, 27, 23, 0).timestamp()
        self.report("s1", [(late, late + 2 * H, False)], {"PROJ-1": 100})
        added = worklog.time_add(self.store, {"key": "PROJ-2", "start": at(late + 0.5 * H), "minutes": 60})["added"]
        self.assertEqual(sorted(added["cut"], key=str), sorted([{"key": "PROJ-1", "seconds": 0.5 * H, "inSprint": True},
                                                                {"key": "PROJ-1", "seconds": 0.5 * H, "inSprint": False, "elsewhere": True}], key=str))

    def test_under_a_minute_taken_is_not_listed_but_said(self):
        self.report("s1", [(T0 - H, T0 + 40, False)], {"PROJ-1": 100})
        added = self.add(T0, 30, item="面試", newItem=True)["added"]
        self.assertEqual((added["cut"], added["cutMinor"], added["cutMinorIn"]), ([], 40, 40))
        self.assertFalse(self.add(T0 + 5 * H, 30, item="面試")["added"]["cutMinor"])            # over no session
        self.report("s2", [(T0 + 7 * H, T0 + 8 * H + 30, False)], {"OPS-9": 100})              # not one of Sprint7's
        added = self.add(T0 + 8 * H, 30, item="面試")["added"]
        self.assertEqual((added["cutMinor"], added["cutMinorIn"]), (30, 0))

    def test_a_record_written_before_stays_as_it_was(self):
        old = self.store.add_manual(None, T0, 180, "開發", "測試", calendar=True, sprint="Sprint7", counted=True)
        old.pop("overSession")
        self.add(T0 + 4 * H, item="面試", newItem=True)
        self.assertEqual(self.sprint_seconds(), 3.0)
        worklog.time_update(self.store, {"id": old["id"], "minutes": 120})
        self.assertNotIn("item", old)
        with self.assertRaises(ValueError):
            worklog.time_update(self.store, {"id": old["id"], "note": " "})               # under no item: still says what it was

    def test_an_items_record_needs_no_note_and_its_calendar_event_names_the_item(self):
        self.add(T0, item="面試", newItem=True, calendar=True)
        self.add(T0 + H, item="面試", note="二面", calendar=True)
        self.add(T0 + 2 * H, item="面試", note="面試", calendar=True)                     # said once
        entry = self.store.segments["manual"][0]
        worklog.time_update(self.store, {"id": entry["id"], "note": ""})
        titles = sorted(e["title"] for e in self.store.calendar_entries(T0 + 3 * H) if e["marker"].startswith("sprint:manual:"))
        self.assertEqual(titles, ["面試 二面（會議）", "面試（會議）", "面試（會議）"])


if __name__ == "__main__":
    unittest.main()
