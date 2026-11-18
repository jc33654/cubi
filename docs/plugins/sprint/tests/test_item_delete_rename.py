"""Batch 45: a work item can be deleted (with its records, its sessions' bindings and its stamp on
their stretches; the files copied first) and renamed (into another there is: the two become one).
Names that differ only in case are one item."""
import json
import os
import unittest
from datetime import datetime

import item_actions
import worklog
from tests.test_items import Base, H, T0, sess

at = lambda ts: datetime.fromtimestamp(ts).isoformat(timespec="minutes")   # noqa: E731
S6 = datetime(2026, 11, 5, 9, 0).timestamp()


class ItemDeleteRenameTests(Base):
    def setUp(self):
        super().setUp()
        self.store.new_sprint("Sprint6", "", "2026-11-02", "2026-11-13")
        self.store.sprints["current"] = "Sprint7"

    def add(self, start, minutes=60, **p):
        return worklog.time_add(self.store, {"key": "", "start": at(start), "minutes": minutes, "kind": "會議", **p})

    def data(self):
        return json.loads(json.dumps((self.store.sprints, self.store.bindings, self.store.segments)))

    def delete(self, name, confirm=True):
        return item_actions.item_delete(self.store, {"name": name, "confirm": confirm})

    def rename(self, name, to, confirm=True):
        return item_actions.item_rename(self.store, {"name": name, "to": to, "confirm": confirm, "now": T0})

    # ---------- delete ----------

    def test_deleting_says_first_what_goes_and_changes_nothing(self):
        self.store.add_item("事故", True)
        self.add(T0, item="事故", calendar=True, note="復盤")
        self.add(S6, 30, item="事故")
        self.bind("s1", "事故")
        self.report("s1", [(T0 + 2 * H, T0 + 3 * H, False)])
        before = self.data()
        said = self.delete("事故", confirm=False)["itemDelete"]
        self.assertEqual(self.data(), before)
        self.assertEqual((said["records"], said["bySprint"], said["calendar"], said["sessions"]),
                         (2, [{"sprint": "Sprint6", "records": 1}, {"sprint": "Sprint7", "records": 1}], 1, 1))
        self.assertEqual((said["autoSeconds"], said["recordSeconds"]), (H, 1.5 * H))
        self.assertEqual(said["changes"], [{"sprint": "Sprint6", "before": 0.5 * H, "after": 0.0}, {"sprint": "Sprint7", "before": 2 * H, "after": 0.0}])
        self.assertIn("已寫進行事曆的事件不會跟著刪，要自己到行事曆清：11/17 09:00–10:00「事故 復盤（會議）」", said["calendarLeft"])
        self.assertNotIn("backup", said)
        self.assertFalse((self.store.root / item_actions.BACKUPS).exists())

    def test_deleting_takes_its_records_bindings_and_stamps_with_it_after_a_copy(self):
        self.store.add_item("事故", True)
        self.add(T0, item="事故")
        self.bind("s1", "事故")
        self.report("s1", [(T0 + 2 * H, T0 + 3 * H, False)])
        self.assertEqual(self.sprint_seconds(), 2.0)
        before = self.data()
        said = self.delete("事故")["itemDeleted"]
        self.assertEqual((self.store.segments["manual"], self.store.sprints["items"], self.store.bindings["s1"].get("item")), ([], {}, None))
        seg = self.store.segments["sessions"]["s1"][str(int(T0 + 2 * H))]
        self.assertEqual((seg.get("item"), seg.get("counted"), seg["itemDeleted"]), (None, None, "事故"))
        self.assertEqual(self.sprint_seconds(), 0.0)
        copied = []
        for f in item_actions.BACKED_UP:
            with open(os.path.join(os.path.expanduser(said["backup"]), f), encoding="utf-8") as fh:
                copied.append(json.load(fh))
        self.assertEqual(copied, before)
        self.assertTrue(os.path.expanduser(said["backup"]).startswith(str(self.store.root / "backups")))

    def test_a_session_still_running_does_not_stamp_the_unstamped_stretches_again(self):
        self.bind("s1", "事故")
        self.report("s1", [(T0, T0 + H, False)])
        self.delete("事故")
        self.bind("s1", "PROJ-1")
        self.report("s1", [(T0, T0 + H, False), (T0 + 2 * H, T0 + 3 * H, False)])
        self.assertEqual(self.hours("PROJ-1"), 1.0)                                        # only the stretch after

    def test_a_record_deleted_gives_back_what_it_took_from_a_session(self):
        self.store.add_item("休息", False)
        self.report("s1", [(T0, T0 + 2 * H, False)], {"PROJ-1": 100})
        self.add(T0, item="休息")
        self.assertEqual(self.hours("PROJ-1"), 1.0)
        said = self.delete("休息", confirm=False)["itemDelete"]
        self.assertEqual(said["changes"], [{"sprint": "Sprint7", "before": H, "after": 2 * H}])
        self.delete("休息")
        self.assertEqual(self.hours("PROJ-1"), 2.0)

    def test_an_item_timing_is_not_deleted_and_an_empty_one_is(self):
        self.bind("s1", "事故")
        self.store.timer_start("s1", T0)
        with self.assertRaises(ValueError) as e:
            self.delete("事故")
        self.assertIn("還在計時", str(e.exception))
        self.store.add_item("測試會議", False)
        entry = self.add(T0, item="測試會議")
        worklog.time_remove(self.store, {"id": self.store.segments["manual"][-1]["id"]})
        self.assertTrue(entry)
        said = self.delete("測試會議")["itemDeleted"]
        self.assertEqual((said["records"], said["sessions"], said["changes"]), (0, 0, []))
        self.assertNotIn("測試會議", self.store.sprints["items"])

    def test_the_newest_twenty_copies_stay(self):
        root = self.store.root / item_actions.BACKUPS
        for n in range(22):
            folder = os.path.expanduser(item_actions.backup(self.store, self.data(), T0, "delete"))
            os.utime(folder, (T0 + n, T0 + n))
        mine = root / "00000000-000000-item-delete"
        mine.mkdir()
        open(mine / "notes.txt", "w").close()
        os.utime(mine, (T0 - 10, T0 - 10))
        item_actions.backup(self.store, self.data(), T0, "delete")
        left = sorted(os.listdir(root))
        self.assertIn(mine.name, left)                                                     # holds something else: left alone
        self.assertEqual(len(left), 21)

    def test_deleting_a_record_on_the_calendar_says_its_event_stays(self):
        self.store.add_item("事故", True)
        self.add(T0, item="事故", calendar=True)
        out = worklog.time_remove(self.store, {"id": self.store.segments["manual"][0]["id"]})
        self.assertEqual(out["calendarLeft"], "已寫進行事曆的事件不會跟著刪，要自己到行事曆清：11/17 09:00–10:00「事故（會議）」")
        self.add(T0, item="事故")
        self.assertNotIn("calendarLeft", worklog.time_remove(self.store, {"id": self.store.segments["manual"][0]["id"]}))

    def test_a_session_using_it_now_is_named_before_deleting(self):
        # F45-1: the rest of a stretch open for the item counts nowhere, even bound to a ticket after.
        self.bind("s1", "事故")
        self.bind("s2", "事故")
        self.report("s1", [(T0, T0 + H, True)])
        self.report("s2", [(T0 - 3 * H, T0 - 2 * H, False)])
        said = item_actions.item_delete(self.store, {"name": "事故", "now": T0 + H + 60})["itemDelete"]
        self.assertEqual(said["inUse"], ["x"])                                              # the session's name
        self.delete("事故")
        self.bind("s1", "PROJ-1")
        self.report("s1", [(T0, T0 + 3 * H, True)])
        self.assertEqual(self.hours("PROJ-1"), 0.0)                                         # said so
        self.report("s1", [(T0, T0 + 3 * H, False), (T0 + 4 * H, T0 + 5 * H, True)])
        self.assertEqual(self.hours("PROJ-1"), 1.0)                                         # the next stretch

    def test_sharing_over_the_whole_sprint_leaves_a_work_items_stretches_alone(self):
        # F45-2: deleted or only let go, a work item's stretch never takes ticket shares (it was counted twice).
        for sid, gone in (("s1", True), ("s2", False)):
            with self.subTest(gone=gone):
                self.store.add_item(f"項目{sid}", True)
                self.bind(sid, f"項目{sid}")
                self.report(sid, [(T0 + 4 * H * (sid == "s2"), T0 + H + 4 * H * (sid == "s2"), False)])
                if gone:
                    self.delete(f"項目{sid}")
                else:
                    worklog.session_unbind(self.store, {**sess(sid, []), "input": f"項目{sid}"})
                self.bind(sid, "PROJ-2")
                self.report(sid, [(T0 + 2 * H + 4 * H * (sid == "s2"), T0 + 3 * H + 4 * H * (sid == "s2"), False)])
                before = (self.hours("PROJ-2"), self.sprint_seconds())
                worklog.session_shares(self.store, {**sess(sid, []), "shares": {"PROJ-2": 100}, "applyToSprint": True})
                self.assertEqual((self.hours("PROJ-2"), self.sprint_seconds()), before)

    def test_pruning_never_follows_a_link(self):
        # F45-3: a link named like a copy, to a folder outside, is never followed.
        root = self.store.root / item_actions.BACKUPS
        root.mkdir()
        outside = self.store.root / "outside"
        outside.mkdir()
        (outside / "sprints.json").write_text("{}")
        os.symlink(outside, root / "20000101-000000-item-delete")
        inner = root / "20000101-000001-item-delete"
        inner.mkdir()
        os.symlink(outside / "sprints.json", inner / "sprints.json")
        for n in range(item_actions.KEEP + 1):
            item_actions.backup(self.store, self.data(), T0 + n, "delete")
        self.assertTrue((outside / "sprints.json").exists())
        self.assertTrue(os.path.islink(root / "20000101-000000-item-delete") and os.path.islink(inner / "sprints.json"))

    # ---------- rename ----------

    def test_a_rename_moves_every_place_that_names_it(self):
        self.store.add_item("會義", True)
        self.bind("s1", "會義")
        self.report("s1", [(T0, T0 + H, False)])
        self.store.timer_start("s1", T0 + 2 * H)
        self.store.timer_stop("s1", T0 + 3 * H)
        self.add(T0 + 4 * H, item="會義", note="週會")
        hours = self.sprint_seconds()
        said = self.rename("會義", " 會議 ")["itemRenamed"]
        self.assertEqual((said["to"], said["merged"], said["changes"]), ("會議", False, []))
        self.assertEqual(self.store.sprints["items"], {"會議": {"counted": True}})
        self.assertEqual(self.store.bindings["s1"]["item"], "會議")
        self.assertEqual([(m["item"], m["note"]) for m in self.store.segments["manual"]], [("會議", "會議"), ("會議", "週會")])
        self.assertEqual({seg["item"] for seg in self.store.segments["sessions"]["s1"].values()}, {"會議"})
        self.assertEqual(self.sprint_seconds(), hours)
        with self.assertRaises(ValueError):
            self.rename("會議", " 會議")                                                     # the same name: refused
        self.store.add_item("cubi", False)
        self.assertEqual(self.rename("cubi", "Cubi")["itemRenamed"]["merged"], False)        # its own case: a plain rename

    def test_a_rename_into_another_item_makes_them_one(self):
        # The acceptance table: Sprint6 30m of A stays; Sprint7 3m47s of B + 1h47m10s of A = 1h50m57s; three items → two.
        self.store.add_item("工具", False)
        self.store.add_item("Cubiiii", False)
        self.store.add_item("CUBIIII", False)
        self.add(S6, 30, item="工具")
        self.bind("s1", "工具")
        self.report("s1", [(T0, T0 + 6430, False)])
        self.bind("s2", "Cubiiii")
        self.report("s2", [(T0 + 3 * H, T0 + 3 * H + 227, False)])
        before = self.data()
        asked = self.rename("Cubiiii", "工具", confirm=False)["itemRename"]
        self.assertEqual((asked["merged"], asked["to"]), (True, "工具"))
        self.assertEqual(self.data(), before)
        said = self.rename("Cubiiii", "工具")["itemRenamed"]
        self.assertTrue(os.path.isdir(os.path.expanduser(said["backup"])))
        self.assertEqual(sorted(self.store.sprints["items"]), ["CUBIIII", "工具"])
        work = {s: [(w["item"], round(w["seconds"])) for w in self.store.item_work(self.store.sprint(s))] for s in ("Sprint6", "Sprint7")}
        self.assertEqual(work, {"Sprint6": [], "Sprint7": [("工具", 6657)]})
        self.assertEqual([(m["item"], self.store.sprint_of(m)) for m in self.store.segments["manual"]], [("工具", "Sprint6")])
        self.assertEqual(self.store.bindings["s2"]["item"], "工具")

    def test_what_is_merged_in_the_sprint_of_now_takes_the_setting_earlier_sprints_keep_theirs(self):
        self.store.add_item("會議", True)
        self.store.add_item("meeting", False)
        self.add(S6, 30, item="meeting")
        self.add(T0, item="meeting")
        self.assertEqual(self.sprint_seconds(), 0.0)
        said = self.rename("meeting", "會議")["itemRenamed"]
        self.assertEqual((said["sprint"], said["counted"], said["changes"]), ("Sprint7", True, [{"sprint": "Sprint7", "before": 0.0, "after": H}]))
        self.assertEqual([(m["item"], m["counted"]) for m in self.store.segments["manual"]], [("會議", False), ("會議", True)])

    def test_a_name_differing_only_in_case_is_the_item_there(self):
        self.store.add_item("Cubi", True)
        with self.assertRaises(ValueError) as e:
            self.rename("Cubi", "Cubi")
        self.assertIn("已經是這個名字", str(e.exception))
        self.store.add_item("其他", False)
        self.assertEqual(self.rename("其他", "CUBI", confirm=False)["itemRename"]["to"], "Cubi")
        worklog.session_bind(self.store, {**sess("s1", []), "input": "cubi"})
        self.assertEqual(self.store.bindings["s1"]["item"], "Cubi")
        with self.assertRaises(ValueError) as e:
            self.add(T0, item="CUBI", newItem=True)
        self.assertIn("已有「Cubi」（大小寫不同也算同一個）", str(e.exception))
        self.assertEqual(self.add(T0, item="cubi")["added"]["item"], "Cubi")
        self.assertEqual(sorted(self.store.sprints["items"]), ["Cubi", "其他"])


if __name__ == "__main__":
    unittest.main()
