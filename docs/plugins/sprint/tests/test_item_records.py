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
        self.assertEqual(self.add(T0 + 5 * H, 30, item="小工具開發")["added"]["cut"], [{"item": "雜事", "seconds": 0.5 * H}])

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
