"""F5a: adding time the quick way and editing a manual stretch. Case numbers are the PRD's."""
import tempfile
import unittest
from datetime import datetime
from unittest import mock

import review
import sprint
import worklog
from store import Store


def ts(text):
    return datetime.fromisoformat(text).timestamp()


NOW = ts("2026-11-18T15:00:30")


class WorklogTests(unittest.TestCase):
    def setUp(self):
        self.dir = tempfile.TemporaryDirectory()
        self.store = Store(self.dir.name)
        self.store.config.update(projectKey="PROJ", site="jira.example")
        self.store.new_sprint("Sprint7", "", "2026-11-16", "2026-11-29")
        self.store.add_to_sprint("Sprint7", "PROJ-1")
        self.store.ticket("PROJ-1").update(summary="甲", estimate=1.0)
        for target in ("worklog.time.time", "panel.time.time"):
            clock = mock.patch(target, return_value=NOW)
            clock.start()
            self.addCleanup(clock.stop)

    def tearDown(self):
        self.store.close()
        self.dir.cleanup()

    def row(self):
        return sprint.panel_state(self.store, {})["sprint"]["tickets"][0]

    def entry(self, **more):
        m = self.store.add_manual("PROJ-1", ts("2026-11-18T10:00"), 60, "開發", "原本的備註", calendar=True)
        m.update(more)
        return m

    # ---------- quick add ----------

    def test_F5_1_only_a_ticket_and_a_length_ends_now(self):
        state = sprint.time_add(self.store, {"key": "PROJ-1", "minutes": 60})
        m = self.store.segments["manual"][-1]
        self.assertEqual((m["start"], m["end"], m["key"], m["kind"]), (NOW - 3600, NOW, "PROJ-1", "開發"))
        self.assertEqual(state["sprint"]["tickets"][0]["seconds"], 3600)
        # An empty start is no start; one that is given is used as before.
        sprint.time_add(self.store, {"key": "PROJ-1", "minutes": 30, "start": ""})
        self.assertEqual(self.store.segments["manual"][-1]["end"], NOW)
        sprint.time_add(self.store, {"key": "PROJ-1", "minutes": 30, "start": "2026-11-17T09:00"})
        self.assertEqual(self.store.segments["manual"][-1]["start"], ts("2026-11-17T09:00"))

    def test_an_added_stretch_says_which_sprint_holds_it(self):
        self.store.new_sprint("Sprint6", "", "2026-11-02", "2026-11-15")
        state = sprint.time_add(self.store, {"key": "PROJ-1", "minutes": 60})
        self.assertEqual(state["added"], {"key": "PROJ-1", "start": NOW - 3600, "end": NOW, "sprint": "Sprint7", "inSprint": True,
                                          "cut": [], "autoPush": False})
        state = sprint.time_add(self.store, {"key": "PROJ-1", "minutes": 30, "start": "2026-11-10T09:00"})
        self.assertEqual((state["added"]["sprint"], state["added"]["inSprint"], state["added"]["end"] - state["added"]["start"]), ("Sprint6", False, 1800))
        self.store.add_to_sprint("Sprint6", "PROJ-1")
        state = sprint.time_add(self.store, {"key": "PROJ-1", "minutes": 30, "start": "2026-11-10T09:00"})
        self.assertTrue(state["added"]["inSprint"])                              # in Sprint6's tickets now
        state = sprint.time_add(self.store, {"key": "PROJ-1", "minutes": 30, "start": "2026-12-25T09:00"})
        self.assertEqual((state["added"]["sprint"], state["added"]["inSprint"]), (None, False))   # no sprint holds it
        state = sprint.time_add(self.store, {"key": "", "minutes": 30, "start": "2026-11-17T09:00", "note": "支援"})
        self.assertEqual((state["added"]["key"], state["added"]["sprint"], state["added"]["inSprint"]), (None, "Sprint7", True))
        self.assertEqual((state["nowSprint"], state["nowSprintKeys"]), ("Sprint7", ["PROJ-1"]))

    def test_the_panel_says_which_sprint_holds_each_of_the_tickets_stretches(self):
        # Sprint7 on screen; PROJ-1 is in it. Its stretches anywhere are listed, each with the sprint
        # whose days hold it, so the panel can show the ones outside this sprint (and delete them).
        self.store.new_sprint("Sprint6", "", "2026-11-02", "2026-11-13")
        self.store.sprints["current"] = "Sprint7"
        for start in ("2026-11-18T09:00", "2026-11-10T09:00", "2026-12-25T09:00"):
            sprint.time_add(self.store, {"key": "PROJ-1", "minutes": 30, "start": start})
        manual = sprint.panel_state(self.store, {})["sprint"]["manual"]
        self.assertEqual([m["sprintOf"] for m in sorted(manual, key=lambda m: m["start"])], ["Sprint6", "Sprint7", None])
        self.assertNotIn("sprintOf", self.store.segments["manual"][0])            # said to the panel, not stored

    def test_F5_2_lengths_that_are_refused(self):
        for bad, why in ((0, "1 分鐘到 24 小時"), (-30, "1 分鐘到 24 小時"), (1441, "1 分鐘到 24 小時"), (0.5, "1 分鐘到 24 小時"),
                         (float("nan"), "1 分鐘到 24 小時"), (True, "要是數字"), ("abc", "要是數字"), (None, "要是數字"), ([60], "要是數字")):
            for payload in ({"key": "PROJ-1", "minutes": bad}, {"key": "PROJ-1", "minutes": bad, "start": "2026-11-18T10:00"}):
                with self.subTest(minutes=bad, start="start" in payload):
                    with self.assertRaisesRegex(ValueError, why):
                        sprint.time_add(self.store, payload)
        self.assertEqual(self.store.segments["manual"], [])
        sprint.time_add(self.store, {"key": "PROJ-1", "minutes": 1440})
        sprint.time_add(self.store, {"key": "PROJ-1", "minutes": "90"})    # what a form field sends
        self.assertEqual([m["end"] - m["start"] for m in self.store.segments["manual"]], [86400, 5400])

    def test_F5_8_added_just_after_midnight_on_a_sprints_first_day_is_split_between_the_two(self):
        self.store.new_sprint("Sprint8", "", "2026-11-30", "2026-12-13")
        self.store.add_to_sprint("Sprint8", "PROJ-1")
        with mock.patch("worklog.time.time", return_value=ts("2026-11-30T00:30:00")):
            sprint.time_add(self.store, {"key": "PROJ-1", "minutes": 60})
        self.assertEqual(self.store.segments["manual"][-1]["start"], ts("2026-11-29T23:30:00"))
        for label in ("Sprint7", "Sprint8"):
            since, until = review.sprint_range(self.store.sprint(label))
            self.assertEqual(self.store.hours_by_key(since, until)["PROJ-1"]["total"], 1800, label)

    def test_F5_10_work_with_no_ticket_still_needs_its_start_and_its_note(self):
        with self.assertRaisesRegex(ValueError, "開始時間格式不對"):
            sprint.time_add(self.store, {"minutes": 60, "note": "會"})
        with self.assertRaisesRegex(ValueError, "沒有單號的工作要寫說明"):
            sprint.time_add(self.store, {"start": "2026-11-18T10:00", "minutes": 60})
        with self.assertRaisesRegex(ValueError, "沒有單號的工作要寫說明"):
            sprint.time_add(self.store, {"start": "2026-11-18T10:00", "minutes": 60, "note": "   "})
        self.assertEqual(self.store.segments["manual"], [])

    # ---------- editing ----------

    def test_F5_3_a_longer_stretch_adds_to_the_ticket_and_takes_from_what_is_left(self):
        m = self.entry()
        before = self.row()
        state = sprint.time_update(self.store, {"id": m["id"], "minutes": 90})
        after = state["sprint"]["tickets"][0]
        self.assertEqual((after["seconds"] - before["seconds"], before["remaining"] - after["remaining"]), (1800, 1800))
        self.assertEqual((m["start"], m["end"]), (ts("2026-11-18T10:00"), ts("2026-11-18T11:30")))

    def test_F5_5_a_kind_changed_to_meeting_moves_the_hours_there(self):
        m = self.entry()
        self.assertEqual(self.row()["meetingSeconds"], 0)
        state = sprint.time_update(self.store, {"id": m["id"], "kind": "會議", "note": " 改成開會 "})
        self.assertEqual(state["sprint"]["tickets"][0]["meetingSeconds"], 3600)
        self.assertEqual((m["kind"], m["note"]), ("會議", "改成開會"))

    def test_moving_a_stretch_keeps_its_length_and_only_what_is_given_changes(self):
        m = self.entry()
        sprint.time_update(self.store, {"id": m["id"], "start": "2026-11-17T14:00"})
        self.assertEqual((m["start"], m["end"], m["kind"], m["note"]), (ts("2026-11-17T14:00"), ts("2026-11-17T15:00"), "開發", "原本的備註"))
        sprint.time_update(self.store, {"id": m["id"], "start": "2026-11-17T09:00", "minutes": 15})
        self.assertEqual((m["start"], m["end"]), (ts("2026-11-17T09:00"), ts("2026-11-17T09:15")))
        # An empty field is "not given"; the id must be a stretch that exists.
        sprint.time_update(self.store, {"id": m["id"], "start": "", "kind": "", "minutes": None})
        self.assertEqual((m["start"], m["end"], m["kind"]), (ts("2026-11-17T09:00"), ts("2026-11-17T09:15"), "開發"))
        with self.assertRaisesRegex(ValueError, "找不到這筆時段"):
            sprint.time_update(self.store, {"id": "nope", "minutes": 30})
        for bad, why in (({"minutes": 0}, "1 分鐘到 24 小時"), ({"minutes": 1441}, "1 分鐘到 24 小時"), ({"minutes": "abc"}, "要是數字"), ({"start": "昨天"}, "開始時間格式不對")):
            with self.assertRaisesRegex(ValueError, why):
                sprint.time_update(self.store, {"id": m["id"], **bad})
        self.assertEqual((m["start"], m["end"]), (ts("2026-11-17T09:00"), ts("2026-11-17T09:15")))

    def test_the_panels_minute_is_not_a_move(self):
        # A stretch added the quick way starts on some second; the panel shows and sends the minute.
        sprint.time_add(self.store, {"key": "PROJ-1", "minutes": 60})
        m = self.store.segments["manual"][-1]
        sprint.time_update(self.store, {"id": m["id"], "start": "2026-11-18T14:00", "minutes": 90})
        self.assertEqual((m["start"], m["end"]), (NOW - 3600, NOW - 3600 + 5400))

    def test_work_with_no_ticket_can_be_edited_and_keeps_needing_a_note(self):
        sprint.time_add(self.store, {"start": "2026-11-18T10:00", "minutes": 60, "note": "面試", "kind": "其他"})
        m = self.store.segments["manual"][-1]
        state = sprint.time_update(self.store, {"id": m["id"], "minutes": 30, "note": "面試（半小時）"})
        self.assertEqual([(x["note"], x["end"] - x["start"]) for x in state["sprint"]["other"]], [("面試（半小時）", 1800)])
        with self.assertRaisesRegex(ValueError, "沒有單號的工作要寫說明"):
            sprint.time_update(self.store, {"id": m["id"], "note": "  "})
        self.assertEqual(m["note"], "面試（半小時）")

    # ---------- stretches a timer booked ----------

    def timed(self):
        """A one-hour timer of session s1, with 20 of the session's own minutes inside it."""
        m = self.entry(session="s1", shares={"PROJ-1": 100.0}, kind="計時", note="")
        self.store.segments["sessions"]["s1"] = {str(int(ts("2026-11-18T10:10"))): {"end": ts("2026-11-18T10:30"), "shares": {"PROJ-1": 100.0}, "open": False, "name": "PROJ-1"}}
        return m

    def test_F5_4_a_timers_stretch_keeps_its_start_kind_and_note(self):
        m = self.timed()
        for change, why in (({"start": "2026-11-18T09:00"}, "不能改開始時間"), ({"kind": "會議"}, "只能改長度或刪除"), ({"note": "補一句"}, "只能改長度或刪除")):
            with self.subTest(change=change):
                with self.assertRaisesRegex(ValueError, why):
                    sprint.time_update(self.store, {"id": m["id"], **change})
        self.assertEqual((m["start"], m["end"], m["kind"], m["note"]), (ts("2026-11-18T10:00"), ts("2026-11-18T11:00"), "計時", ""))
        # The same start and the same words, as the panel sends them along with a new length: fine.
        sprint.time_update(self.store, {"id": m["id"], "start": "2026-11-18T10:00", "kind": "計時", "note": "", "minutes": 45})
        self.assertEqual(m["end"], ts("2026-11-18T10:45"))

    def test_F5_9_a_shorter_timer_is_matched_against_the_sessions_stretches_again(self):
        m = self.timed()
        total = lambda: self.store.hours_by_key()["PROJ-1"]["total"]   # noqa: E731
        self.assertEqual(total(), 3600)                       # 20 min of the session + 40 the timer adds
        sprint.time_update(self.store, {"id": m["id"], "minutes": 30})
        self.assertEqual(total(), 1800)                       # 10:00–10:30: 20 of the session + 10 of the timer
        sprint.time_update(self.store, {"id": m["id"], "minutes": 5})
        self.assertEqual(total(), 1500)                       # 10:00–10:05 + the session's own 10:10–10:30, none twice, none lost
        sprint.time_update(self.store, {"id": m["id"], "minutes": 120})
        self.assertEqual(total(), 7200)

    # ---------- the calendar ----------

    def notices(self, m, **change):
        return sprint.time_update(self.store, {"id": m["id"], **change}).get("notices", [])

    def test_F5_7_the_calendar_is_only_followed_when_a_recent_stretch_just_gets_longer(self):
        said = [worklog.CALENDAR_STALE]
        m = self.entry()                                    # 10:00–11:00 today, on the calendar
        self.assertEqual(self.notices(m, minutes=90), [])                        # longer: cubi extends the event
        self.assertEqual(self.notices(m, minutes=90, kind="開發", note="原本的備註"), [])   # nothing changed
        self.assertEqual(self.notices(m, minutes=60), said)                      # shorter
        self.assertEqual(self.notices(m, start="2026-11-18T09:00"), said)        # moved
        self.assertEqual(self.notices(m, start="2026-11-18T09:30", minutes=120), said)   # later start, later end: still a move
        self.assertEqual(self.notices(m, kind="會議"), said)                     # the title changes
        self.assertEqual(self.notices(m, note="新的備註"), said)
        old = self.store.add_manual("PROJ-1", ts("2026-11-15T10:00"), 60, calendar=True)   # three days ago
        self.assertEqual(self.notices(old, minutes=90), said)                    # too old to be sent again
        off = self.store.add_manual("PROJ-1", ts("2026-11-18T13:00"), 60, calendar=False)
        self.assertEqual(self.notices(off, minutes=30), [])                      # never on the calendar


if __name__ == "__main__":
    unittest.main()
