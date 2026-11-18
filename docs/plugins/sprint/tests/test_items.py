"""Batch 36: a manual record (a form entry or a booked timer) wins over every session's own
stretches over the same minutes, whatever their ticket; two sessions do not cut each other. A
session can be bound to a work item of the user's own instead of tickets: its time is work with
no ticket, counted in the sprint only if the item says so (as it said when the time was written),
and it never goes to Jira or the calendar."""
import os
import tempfile
import unittest
from datetime import datetime

import autopush
import card
import sprint  # noqa: F401  (loads the modules in the order the plugin does)
import worklog
from card import session_info
from review import metrics
from store import Store

H = 3600.0
T0 = datetime(2026, 11, 17, 9, 0).timestamp()


def sess(sid, segments, name="x"):
    return {"id": sid, "name": name, "cwd": None, "segments": [{"start": a, "end": b, "open": o} for a, b, o in segments]}


class Base(unittest.TestCase):
    def setUp(self):
        self.dir = tempfile.TemporaryDirectory()
        self.store = Store(self.dir.name)
        self.store.new_sprint("Sprint7", "", "2026-11-16", "2026-11-27")
        for key in ("PROJ-1", "PROJ-2"):
            self.store.add_to_sprint("Sprint7", key)
            self.store.ticket(key)

    def tearDown(self):
        self.store.close()
        self.dir.cleanup()

    def report(self, sid, segments, shares=None):
        """What a tick does with one session cubi reports."""
        s = sess(sid, segments)
        rec = self.store.binding(s)
        self.store.record_segments(s, shares if shares is not None else self.store.shares(rec), self.store.item_stamp(rec))

    def hours(self, key):
        return self.store.hours_by_key().get(key, {}).get("total", 0.0) / H

    def sprint_seconds(self):
        sp = self.store.current_sprint()
        rows = [{"seconds": self.store.hours_by_key().get(k, {}).get("total", 0.0), "estimate": None, "actual": None,
                 "meetingSeconds": 0.0, "kinds": {}, "done": False, "doneAt": None, "category": None} for k in sp["keys"]]
        return metrics(rows, self.store.no_ticket_work(sp))["seconds"] / H

    def bind(self, sid, text):
        return worklog.session_bind(self.store, {**sess(sid, []), "input": text})


class ItemsTests(Base):
    # ---------- one moment counts once: manual over session ----------

    def test_work_with_no_ticket_over_a_session_counts_once(self):                     # A + D
        self.report("s1", [(T0, T0 + 2 * H, False)], {"PROJ-1": 100})
        self.store.add_manual(None, T0 + H, 60, "會議", "事故會議", sprint="Sprint7", counted=True)
        self.assertEqual(self.hours("PROJ-1"), 1.0)
        self.assertEqual(self.sprint_seconds(), 2.0)

    def test_work_with_no_ticket_left_out_of_the_sprint_takes_its_minutes_out_too(self):
        self.report("s1", [(T0, T0 + 2 * H, False)], {"PROJ-1": 100})
        self.store.add_manual(None, T0 + H, 60, "會議", "別組的會", sprint="Sprint7", counted=False)
        self.assertEqual(self.hours("PROJ-1"), 1.0)
        self.assertEqual(self.sprint_seconds(), 1.0)

    def test_another_tickets_entry_over_a_session_counts_once(self):                  # A + C
        self.report("s1", [(T0, T0 + 2 * H, False)], {"PROJ-1": 100})
        self.store.add_manual("PROJ-2", T0 + H, 60, "會議")
        self.assertEqual((self.hours("PROJ-1"), self.hours("PROJ-2")), (1.0, 1.0))
        self.assertEqual(self.sprint_seconds(), 2.0)

    def test_a_timer_over_its_own_session_and_a_parallel_one_counts_once(self):      # A + B
        self.report("s1", [(T0, T0 + 2 * H, False)], {"PROJ-1": 100})
        self.report("s2", [(T0, T0 + 2 * H, False)], {"PROJ-2": 100})
        self.store.bind("s1", "PROJ-1")
        self.store.timer_start("s1", T0 + H)
        self.store.timer_stop("s1", T0 + 2 * H)
        # The timer's hour is PROJ-1's; both sessions give it up, s2 keeps its first hour.
        self.assertEqual((self.hours("PROJ-1"), self.hours("PROJ-2")), (2.0, 1.0))
        self.assertEqual(self.store.session_seconds("s1"), 2 * H)

    def test_two_sessions_at_once_both_count(self):                                    # A + A
        self.report("s1", [(T0, T0 + 2 * H, False)], {"PROJ-1": 100})
        self.report("s2", [(T0, T0 + 2 * H, False)], {"PROJ-2": 100})
        self.store.add_manual("PROJ-1", T0 + 5 * H, 60)                                 # elsewhere in the day
        self.assertEqual((self.hours("PROJ-1"), self.hours("PROJ-2")), (3.0, 2.0))

    def test_records_from_before_the_mark_leave_the_sessions_alone(self):
        self.report("s1", [(T0, T0 + 2 * H, False)], {"PROJ-1": 100})
        old = self.store.add_manual(None, T0 + H, 60, "會議", "舊的", sprint="Sprint7")
        del old["overSession"]
        self.assertEqual(self.hours("PROJ-1"), 2.0)
        self.assertEqual(self.sprint_seconds(), 3.0)                                   # counted twice, as it always was

    def test_a_new_record_over_an_old_stretch_still_takes_its_minutes(self):
        self.report("s1", [(T0, T0 + 2 * H, False)], {"PROJ-1": 100})
        del self.store.segments["sessions"]["s1"][str(int(T0))]["added"]              # a stretch from before batch 19
        self.store.add_manual(None, T0, 30, "會議", "補記", sprint="Sprint7")
        self.assertEqual(self.hours("PROJ-1"), 1.5)

    # ---------- binding a work item ----------

    def test_binding_takes_a_name_and_a_session_has_tickets_or_an_item(self):
        out = self.bind("s1", "  小工具   開發 ")
        self.assertEqual(self.store.bindings["s1"]["item"], "小工具 開發")
        self.assertEqual(self.store.sprints["items"], {"小工具 開發": {"counted": False}})
        self.assertIn({"label": "工作項目", "value": "小工具 開發 · 不算進 sprint 投入",
                       "action": {"label": "解除 小工具 開發", "action": "session.unbind", "arg": "小工具 開發", "icon": "xmark"}}, out["rows"])
        with self.assertRaisesRegex(ValueError, "只能二選一：先解除「小工具 開發」再綁單號"):
            self.bind("s1", "PROJ-2")
        self.bind("s2", "PROJ-2")
        with self.assertRaisesRegex(ValueError, "已綁 PROJ-2。單號和工作項目只能二選一"):
            self.bind("s2", "雜事")

    def test_a_session_with_an_item_keeps_it_until_let_go(self):
        self.bind("s1", "Cubiiii")
        with self.assertRaisesRegex(ValueError, "已綁「Cubiiii」。一個 session 只能一個工作項目：先解除再綁「小工具開發」"):
            self.bind("s1", "小工具開發")
        self.bind("s1", "Cubiiii")                                                      # the same one: nothing to do
        self.assertEqual(self.store.bindings["s1"]["item"], "Cubiiii")
        self.assertEqual(self.store.sprints["items"], {"Cubiiii": {"counted": False}})
        worklog.session_unbind(self.store, {**sess("s1", []), "input": "Cubiiii"})
        self.bind("s1", "小工具開發")
        self.assertEqual(self.store.bindings["s1"]["item"], "小工具開發")

    def test_a_name_that_looks_like_a_ticket_is_refused(self):
        for text in ("OTHER-12", "看 web-3 的問題", ""):
            with self.subTest(text=text), self.assertRaises(ValueError):
                self.bind("s1", text)
        with self.assertRaisesRegex(ValueError, "最多 24 個字"):
            self.bind("s1", "長" * 25)
        self.assertNotIn("items", self.store.sprints)

    def test_a_key_in_the_sessions_name_waits_while_an_item_is_bound(self):
        s = sess("s1", [], name="PROJ-1 修 bug")
        self.store.binding(s)
        worklog.session_unbind(self.store, {**s, "input": "PROJ-1"})
        self.bind("s1", "小工具開發")
        self.store.binding(s)                                                           # the name read again
        self.assertEqual(self.store.bound_keys(self.store.bindings["s1"]), [])
        worklog.session_unbind(self.store, {**s, "input": "小工具開發"})
        self.assertNotIn("item", self.store.bindings["s1"])

    def test_the_card_offers_both(self):
        out = session_info(self.store, sess("s1", []))
        self.assertIn(["工單", "未綁定；按 ＋ 綁單號或工作項目"], out["rows"])
        self.assertEqual(out["actions"][0]["label"], "綁單號或工作項目")

    # ---------- a work item's time ----------

    def test_switching_counted_moves_the_whole_sprint_of_now_and_no_earlier_one(self):
        """Batch 39 (the owner's choice b): the switch is the item's, for all of this sprint."""
        self.store.new_sprint("Sprint6", "", "2026-11-02", "2026-11-15")
        self.store.sprints["current"] = "Sprint7"
        earlier = datetime(2026, 11, 10, 9, 0).timestamp()
        self.bind("s1", "小工具開發")
        self.report("s1", [(earlier, earlier + H, False), (T0, T0 + H, False)])          # Sprint6, Sprint7
        timed = self.store.add_manual(None, T0 + 2 * H, 30, "計時", "小工具開發", False, sprint="Sprint7",
                                      counted=False, item="小工具開發")
        old = self.store.add_manual(None, earlier + 2 * H, 30, "計時", "小工具開發", False, sprint="Sprint6",
                                    counted=False, item="小工具開發")
        self.assertEqual(self.sprint_seconds(), 0.0)
        out = worklog.item_update(self.store, {"name": "小工具開發", "counted": True, "now": T0 + 4 * H})
        self.assertEqual(out["itemChanged"], {"name": "小工具開發", "counted": True, "sprint": "Sprint7", "seconds": 1.5 * H})
        self.assertEqual(self.sprint_seconds(), 1.5)                                    # closed stretch and timer both
        self.assertTrue(timed["counted"])
        self.assertEqual((old["counted"], self.store.segments["sessions"]["s1"][str(int(earlier))]["counted"]), (False, False))
        self.report("s1", [(T0, T0 + H, False), (T0 + 5 * H, T0 + 6 * H, True)])          # written after: counted
        self.assertEqual(self.sprint_seconds(), 2.5)
        worklog.item_update(self.store, {"name": "小工具開發", "counted": False, "now": T0 + 6 * H})
        self.assertEqual(self.sprint_seconds(), 0.0)
        self.assertEqual(self.store.hours_by_key(), {})

    def test_switching_with_no_sprint_holding_now_takes_the_one_on_screen(self):
        self.bind("s1", "雜事")
        self.report("s1", [(T0, T0 + H, False)])
        later = datetime(2026, 12, 25, 9, 0).timestamp()                                 # no sprint holds it
        out = worklog.item_update(self.store, {"name": "雜事", "counted": True, "now": later})
        self.assertEqual((out["itemChanged"]["sprint"], out["itemChanged"]["seconds"]), ("Sprint7", H))
        self.assertEqual(self.sprint_seconds(), 1.0)

    def test_its_timer_books_work_with_no_ticket_never_on_the_calendar_or_jira(self):
        self.store.config.update(autoPushHours=True, actualHoursField="customfield_1")
        self.bind("s1", "小工具開發")
        worklog.item_update(self.store, {"name": "小工具開發", "counted": True})
        self.report("s1", [(T0, T0 + 2 * H, False)])
        self.store.timer_start("s1", T0 + H)
        entry, _ = self.store.timer_stop("s1", T0 + 2 * H)
        self.assertEqual({k: entry[k] for k in ("key", "item", "note", "kind", "calendar", "counted", "sprint", "session")},
                         {"key": None, "item": "小工具開發", "note": "小工具開發", "kind": "計時", "calendar": False,
                          "counted": True, "sprint": "Sprint7", "session": "s1"})
        self.assertEqual(autopush.keys_of(entry), [])
        self.assertEqual(self.sprint_seconds(), 2.0)                                   # 1 h automatic + 1 h timed, once
        self.assertEqual(self.store.calendar_entries(T0 + 3 * H), [])
        self.assertFalse(any(t.get("hoursPush") for t in self.store.tickets.values()))

    def test_a_stretch_cubi_lost_while_running_is_no_longer_running(self):
        """Cubi restarted while a stretch ran: the session's next report has a new one only."""
        self.report("s1", [(T0, T0 + H, True)])
        self.report("s1", [(T0 + 3 * H, T0 + 3.5 * H, True)])
        sess = self.store.segments["sessions"]["s1"]
        self.assertEqual({k: (v["open"], v.get("lost", False)) for k, v in sess.items()},
                         {str(int(T0)): (False, True), str(int(T0 + 3 * H)): (True, False)})
        self.report("s1", [(T0 + 3 * H, T0 + 3.5 * H, False)])                           # ended in sight: not lost
        self.assertEqual((sess[str(int(T0 + 3 * H))]["open"], sess[str(int(T0 + 3 * H))].get("lost", False)), (False, False))
        self.report("s1", [(T0, T0 + H, True)])                                          # seen again: not lost any more
        self.report("s1", [(T0, T0 + H, False)])
        self.assertEqual((sess[str(int(T0))]["open"], sess[str(int(T0))].get("lost", False)), (False, False))
        self.report("s1", [(T0 + 4 * H, T0 + 4.5 * H, True)])
        self.store.record_segments({"id": "s1", "name": "x"}, {})                         # no stretches said: left alone
        self.assertTrue(sess[str(int(T0 + 4 * H))]["open"])
        # The calendar keeps away from a lost one, as it did while it was marked running.
        self.report("s5", [(T0, T0 + H, True)], {"PROJ-1": 100})
        self.report("s5", [(T0 + 2 * H, T0 + 3 * H, False)], {"PROJ-1": 100})
        self.assertEqual([e["start"] for e in self.store.calendar_entries(T0 + 4 * H)], [T0 + 2 * H])

    def test_letting_the_item_go_keeps_what_was_written(self):
        self.bind("s1", "小工具開發")
        self.report("s1", [(T0, T0 + H, False)])
        self.store.timer_start("s1", T0 + 2 * H)
        worklog.session_unbind(self.store, {**sess("s1", []), "input": "小工具開發"})
        self.assertEqual(self.store.timer_stop("s1", T0 + 3 * H), (None, "單號和工作項目都解除了，沒有記"))
        self.assertEqual(self.store.item_work(self.store.current_sprint())[0]["seconds"], H)

    def test_the_panel_lists_items_and_their_time(self):
        self.bind("s1", "小工具開發")
        self.report("s1", [(T0, T0 + H, False)])
        state = worklog.panel_state(self.store, {"session": sess("s1", [])})
        self.assertEqual(state["items"], [{"name": "小工具開發", "counted": False, "seconds": H, "sessions": 1}])
        self.assertEqual((state["session"]["item"], state["session"]["itemCounted"]), ("小工具開發", False))
        self.assertEqual(state["sprint"]["itemWork"][0]["seconds"], H)
        self.assertEqual(state["sprint"]["metrics"]["otherSeconds"], 0.0)
        self.assertEqual([b["item"] for b in state["bindings"]], ["小工具開發"])
        with self.assertRaisesRegex(ValueError, "開或關"):
            worklog.item_update(self.store, {"name": "小工具開發", "counted": "yes"})


class JiraHoursTests(Base):
    """F36-1: a manual record that takes minutes out of a session's stretches changes that
    session's tickets too; they wait to have their hours written again, on every path."""

    def setUp(self):
        super().setUp()
        self.store.config.update(autoPushHours=True, actualHoursField="customfield_1")
        self.report("s1", [(T0, T0 + 2 * H, False)], {"PROJ-1": 100})

    def waiting(self):
        out = sorted(k for k, t in self.store.tickets.items() if (t.get("hoursPush") or {}).get("pending"))
        for t in self.store.tickets.values():
            t.pop("hoursPush", None)
        return out

    def add(self, key, start, minutes):
        payload = {"key": key, "start": datetime.fromtimestamp(start).isoformat(timespec="minutes"), "minutes": minutes}
        return worklog.time_add(self.store, payload if key else {**payload, "note": "會議", "item": "雜事", "newItem": "雜事" not in self.store.sprints.get("items", {})})

    def entry(self):
        return self.store.segments["manual"][-1]

    def test_adding_work_with_no_ticket_over_a_session_queues_its_ticket(self):
        self.add("", T0 + H, 60)
        self.assertEqual(self.waiting(), ["PROJ-1"])

    def test_adding_says_which_tickets_gave_way_and_whether_jira_follows(self):
        self.report("s2", [(T0, T0 + 2 * H, False)], {"PROJ-1": 50, "PROJ-2": 50})
        added = self.add("PROJ-2", T0 + H, 30)["added"]
        # PROJ-1 (100% at most at once) lost 30m; PROJ-2 gained the record: not said to give way.
        self.assertEqual(added["cut"], [{"key": "PROJ-1", "seconds": 0.5 * H}])
        self.assertTrue(added["autoPush"])
        self.assertEqual(self.add("", T0 + 5 * H, 60)["added"]["cut"], [])               # over no session
        self.store.config["autoPushHours"] = False
        self.assertFalse(self.add("", T0, 30)["added"]["autoPush"])

    def test_a_record_over_its_own_tickets_session_is_not_said_to_cut_it(self):
        self.assertEqual(self.add("PROJ-1", T0 + 1.5 * H, 30)["added"]["cut"], [])
        self.assertAlmostEqual(self.hours("PROJ-1"), 2.0)

    def test_adding_over_a_work_items_session_says_the_item_gave_way(self):
        worklog.session_bind(self.store, {**sess("s7", []), "input": "小工具開發"})
        self.report("s7", [(T0 + 4 * H, T0 + 6 * H, False)])
        self.assertEqual(self.add("", T0 + 5 * H, 30)["added"]["cut"], [{"item": "小工具開發", "seconds": 0.5 * H}])

    def test_adding_another_tickets_entry_queues_both(self):
        self.add("PROJ-2", T0 + H, 60)
        self.assertEqual(self.waiting(), ["PROJ-1", "PROJ-2"])
        self.add("PROJ-2", T0 + 5 * H, 60)                                             # over no session
        self.assertEqual(self.waiting(), ["PROJ-2"])

    def test_moving_an_entry_queues_the_tickets_it_left_and_the_ones_it_reached(self):
        self.report("s2", [(T0 + 5 * H, T0 + 6 * H, False)], {"PROJ-2": 100})
        self.add("", T0 + H, 60)
        self.waiting()
        worklog.time_update(self.store, {"id": self.entry()["id"], "start": datetime.fromtimestamp(T0 + 5 * H).isoformat(timespec="minutes")})
        self.assertEqual(self.waiting(), ["PROJ-1", "PROJ-2"])
        self.assertEqual(self.hours("PROJ-1"), 2.0)

    def test_removing_an_entry_queues_the_session_ticket_it_gave_back_to(self):
        self.add("", T0 + H, 60)
        self.waiting()
        worklog.time_remove(self.store, {"id": self.entry()["id"]})
        self.assertEqual(self.waiting(), ["PROJ-1"])
        self.assertEqual(self.hours("PROJ-1"), 2.0)

    def test_a_timer_stopped_by_hand_or_as_an_orphan_queues_the_parallel_sessions_ticket(self):
        self.report("s3", [(T0, T0 + 2 * H, False)], {"PROJ-2": 100})
        self.store.bind("s3", "PROJ-2")
        self.store.timer_start("s3", T0 + H)
        worklog.timer_stop(self.store, {"sid": "s3"})
        self.assertEqual(self.waiting(), ["PROJ-1", "PROJ-2"])
        self.store.timer_start("s3", T0 + H)
        self.store.segments["timers"]["s3"]["seen"] = T0 + H
        real, empty = autopush.push_waiting, tempfile.TemporaryDirectory()
        autopush.push_waiting = lambda store: None                                     # tick's Jira round: not here
        os.environ["CUBI_CLAUDE_SESSIONS"] = empty.name
        try:
            card.tick(self.store, {"now": T0 + 3 * H, "sessions": []})
        finally:
            autopush.push_waiting = real
            del os.environ["CUBI_CLAUDE_SESSIONS"]
            empty.cleanup()
        self.assertEqual(self.waiting(), ["PROJ-1", "PROJ-2"])


if __name__ == "__main__":
    unittest.main()
