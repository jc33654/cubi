"""F4: the review day's reminders. Case numbers are the PRD's (docs/prd/sprint-phase1.md)."""
import contextlib
import io
import json
import os
import sys
import tempfile
import unittest
from datetime import date, datetime

import cadence
import remind
import review
import sprint
from store import Store


def ts(text):
    return datetime.fromisoformat(text).timestamp()


class RemindTests(unittest.TestCase):
    """Sprint7 runs 2026-11-16 (Mon) to 2026-11-29 (Sun): review on Thu 11-26, planning on Fri 11-27."""

    def setUp(self):
        self.dir = tempfile.TemporaryDirectory()
        self.store = Store(self.dir.name)
        self.store.config.update(projectKey="PROJ", site="jira.example")
        self.store.new_sprint("Sprint7", "Sprint 7", "2026-11-16", "2026-11-29")
        self.real_today = cadence.today
        self.on(2026, 11, 26)

    def tearDown(self):
        cadence.today = self.real_today
        self.store.close()
        self.dir.cleanup()

    def on(self, *day):
        cadence.today = lambda: date(*day)

    def events(self, when):
        out = sprint.tick(self.store, {"now": ts(when), "sessions": []})["calendar"]
        return [e for e in out if e["marker"].startswith("sprint:review:")]

    def card(self, keys=("PROJ-1",), when="2026-11-26T09:00"):
        session = {"id": "s1", "name": " ".join(keys), "cwd": None, "segments": []}
        for k in keys:
            self.store.ticket(k).update(summary="單", estimate=1.0)
        return session, sprint.session_info(self.store, session)

    # ---------- the calendar event ----------

    def test_F4_1_F4_2_one_event_sent_for_ten_minutes_then_never(self):
        first = self.events("2026-11-26T08:00:00")
        self.assertEqual(first, [{"title": "Sprint review", "start": ts("2026-11-26T10:00"), "end": ts("2026-11-26T10:30"),
                                  "notes": "Sprint 7 的 review", "marker": "sprint:review:Sprint7"}])
        self.assertEqual(self.events("2026-11-26T08:05:00"), first)
        self.assertEqual(self.events("2026-11-26T08:10:00"), first)
        self.assertEqual(self.events("2026-11-26T08:10:01"), [])
        self.assertEqual(self.events("2026-11-26T09:59:00"), [])
        self.assertEqual(self.events("2026-11-27T08:00:00"), [])
        self.assertEqual(self.store.sprint("Sprint7")["reviewEvent"], {"at": ts("2026-11-26T08:00:00"), "day": "2026-11-26", "start": ts("2026-11-26T10:00"), "end": ts("2026-11-26T10:30")})

    def test_the_event_goes_out_from_the_sprints_first_day_and_comes_first(self):
        self.assertEqual(self.events("2026-11-15T23:59:00"), [])                 # not this sprint's days yet
        for i in range(60):                                                       # more than cubi takes in one tick
            self.store.add_manual("PROJ-1", ts("2026-11-16T00:10") + i * 600, 5, calendar=True)
        out = sprint.tick(self.store, {"now": ts("2026-11-16T11:00:00"), "sessions": []})["calendar"]
        self.assertEqual((len(out), out[0]["marker"], out[0]["start"]), (50, "sprint:review:Sprint7", ts("2026-11-26T10:00")))

    def test_F4_9_late_on_the_review_day_it_still_goes_once_the_day_after_it_does_not(self):
        self.assertEqual(len(self.events("2026-11-26T23:30:00")), 1)
        with tempfile.TemporaryDirectory() as d:
            late = Store(d)
            late.new_sprint("Sprint7", "", "2026-11-16", "2026-11-29")
            self.assertEqual(sprint.tick(late, {"now": ts("2026-11-27T00:00:01"), "sessions": []})["calendar"], [])
            self.assertNotIn("reviewEvent", late.sprint("Sprint7"))
            late.close()

    def test_F4_4_no_time_set_means_no_event_and_the_reminders_stay(self):
        self.store.config["reviewEventStart"] = ""
        self.assertEqual(self.events("2026-11-26T08:00:00"), [])
        self.assertNotIn("reviewEvent", self.store.sprint("Sprint7"))
        self.assertTrue(sprint.panel_state(self.store, {})["sprint"]["reviewDue"])
        self.assertEqual(self.card()[1]["rows"][0]["label"], "今天 review")

    def test_F4_7_a_new_time_is_for_sprints_whose_event_has_not_gone_out(self):
        self.events("2026-11-26T08:00:00")
        sprint.config_set(self.store, {"reviewEventStart": "14:00", "reviewEventMinutes": "45"})
        self.assertEqual(self.events("2026-11-26T08:20:00"), [])
        self.store.new_sprint("Sprint8", "", "2026-11-30", "2026-12-13")
        [e] = self.events("2026-11-30T09:00:00")
        self.assertEqual((e["marker"], e["start"], e["end"]), ("sprint:review:Sprint8", ts("2026-12-10T14:00"), ts("2026-12-10T14:45")))
        # Within the ten minutes the event that went out goes again as it was, whatever the setting says now.
        sprint.config_set(self.store, {"reviewEventStart": "16:00"})
        self.assertEqual(self.events("2026-11-30T09:05:00"), [e])

    def test_F4_8_an_end_changed_afterwards_moves_the_reminders_and_says_so_once(self):
        self.events("2026-11-26T08:00:00")
        sprint.sprint_update(self.store, {"label": "Sprint7", "end": "2026-12-06"})
        self.assertEqual(self.events("2026-12-03T08:00:00"), [])                 # the event is not written again
        self.on(2026, 11, 26)
        state = sprint.panel_state(self.store, {})
        self.assertEqual((state["sprint"]["reviewDay"], state["sprint"]["reviewDue"]), ("2026-12-03", False))
        self.assertNotEqual(self.card()[1]["rows"][0]["label"], "今天 review")
        self.assertEqual([h["id"] for h in state["hints"]], ["reviewMoved:Sprint7"])
        self.assertIn("行事曆上的 review 仍在 2026-11-26，請手動調整", state["hints"][0]["text"])
        sprint.hint_seen(self.store, {"id": "reviewMoved:Sprint7"})
        self.assertEqual(sprint.panel_state(self.store, {})["hints"], [])
        self.on(2026, 12, 3)
        self.assertTrue(sprint.panel_state(self.store, {})["sprint"]["reviewDue"])
        self.assertEqual(self.card(when="2026-12-03T09:00")[1]["rows"][0]["label"], "今天 review")

    def test_F4_15_writing_it_again_opens_a_new_ten_minutes_with_todays_day_and_time(self):
        self.events("2026-11-26T08:00:00")
        sprint.sprint_update(self.store, {"label": "Sprint7", "end": "2026-12-06"})
        sprint.config_set(self.store, {"reviewEventStart": "15:30"})
        sprint.panel_state(self.store, {})
        sprint.hint_seen(self.store, {"id": "reviewMoved:Sprint7"})
        state = sprint.review_resend(self.store, {})
        self.assertIsNone(state["sprint"]["reviewEvent"])
        [e] = self.events("2026-11-27T09:00:00")
        self.assertEqual((e["start"], e["end"]), (ts("2026-12-03T15:30"), ts("2026-12-03T16:00")))
        self.assertEqual(self.events("2026-11-27T09:09:00"), [e])
        self.assertEqual(self.events("2026-11-27T09:11:00"), [])
        self.assertEqual(sprint.panel_state(self.store, {})["hints"], [])       # the event and the day agree again

    def test_F4_10_F4_14_older_ends_and_no_end(self):
        with tempfile.TemporaryDirectory() as d:
            s = Store(d)
            s.new_sprint("Sprint6", "", "2026-11-02", "2026-11-13")              # ends on its Friday
            [e] = [x for x in sprint.tick(s, {"now": ts("2026-11-05T09:00"), "sessions": []})["calendar"]]
            self.assertEqual(e["start"], ts("2026-11-12T10:00"))                  # the Thursday before
            s.new_sprint("Short", "", "2026-11-16", "2026-11-24")                # ended by hand on a Tuesday
            [e] = sprint.tick(s, {"now": ts("2026-11-17T09:00"), "sessions": []})["calendar"]
            self.assertEqual(e["start"], ts("2026-11-24T10:00"))
            self.on(2026, 11, 23)
            self.assertFalse(sprint.panel_state(s, {})["sprint"]["reviewDue"])
            self.on(2026, 11, 24)
            self.assertTrue(sprint.panel_state(s, {})["sprint"]["reviewDue"])
            s.new_sprint("Open", "", "2026-12-01", "")                           # no end: nothing at all
            self.assertEqual(sprint.tick(s, {"now": ts("2026-12-03T09:00"), "sessions": []})["calendar"], [])
            self.on(2026, 12, 3)
            state = sprint.panel_state(s, {})["sprint"]
            self.assertEqual((state["label"], state["reviewDay"], state["reviewDue"]), ("Open", None, False))
            s.close()

    # ---------- the card and the panel ----------

    def test_F4_1_F4_3_the_card_and_the_panel_remind_on_the_day(self):
        self.assertEqual(self.card()[1]["rows"][0], {"label": "今天 review", "value": "開 Sprint 面板按「產生回顧」", "tone": "info"})
        self.assertTrue(sprint.panel_state(self.store, {})["sprint"]["reviewDue"])
        for day, due in (((2026, 11, 25), False), ((2026, 11, 27), True), ((2026, 11, 29), True), ((2026, 11, 30), False)):
            self.on(*day)
            self.assertNotEqual(self.card()[1]["rows"][0]["label"], "今天 review", day)   # only on the day itself
            self.assertEqual(sprint.panel_state(self.store, {})["sprint"]["reviewDue"], due, day)

    def test_F4_11_the_card_stays_within_ten_rows_on_the_review_day(self):
        keys = tuple(f"PROJ-{i}" for i in range(1, 9))
        session, out = self.card(keys)
        labels = [r["label"] if isinstance(r, dict) else r[0] for r in out["rows"]]
        self.assertEqual(labels, ["今天 review"] + list(keys[:7]) + ["還有", "今日"])
        self.store.timer_start("s1", ts("2026-11-26T08:00"))
        out = sprint.session_info(self.store, session)
        labels = [r["label"] for r in out["rows"]]
        self.assertEqual(labels, ["今天 review"] + list(keys[:6]) + ["還有", "今日", "計時中"])
        self.assertEqual(next(r["value"] for r in out["rows"] if r["label"] == "還有"), "2 張沒列出：開面板看綁定總覽")
        # Seven tickets fit beside the reminder; on any other day eight still do.
        self.assertEqual(len(self.card(keys[:7])[1]["rows"]), 10)
        self.on(2026, 11, 25)
        self.assertEqual(len([r for r in self.card(keys)[1]["rows"] if r["label"].startswith("PROJ-")]), 8)

    def test_the_event_settings_are_checked(self):
        for bad in ("10", "25:00", "10:60", "10:00:00", "上午十點"):
            with self.assertRaisesRegex(ValueError, "要像 10:00"):
                sprint.config_set(self.store, {"reviewEventStart": bad})
        for bad, why in (("abc", "分鐘數"), ("0", "5 到 480"), ("600", "5 到 480")):
            with self.assertRaisesRegex(ValueError, why):
                sprint.config_set(self.store, {"reviewEventMinutes": bad})
        config = sprint.config_set(self.store, {"reviewEventStart": " 09:30 ", "reviewEventMinutes": "60"})["config"]
        self.assertEqual((config["reviewEventStart"], config["reviewEventMinutes"]), ("09:30", 60))
        self.assertEqual(sprint.config_set(self.store, {"reviewEventStart": ""})["config"]["reviewEventStart"], "")

    # ---------- the snapshot ----------

    def test_F4_6_a_data_file_and_an_export_say_when_their_numbers_were_read(self):
        s = self.store.sprint("Sprint7")
        at = datetime(2026, 11, 26, 16, 5)
        line = "產生於 2026-11-26 16:05，數字截至這個時間（之後記的工時不在裡面）。"
        self.assertIn(line, review.markdown(s, [], review.metrics([]), now=at))
        self.assertIn(line, review.brief(s, [], review.metrics([]), "cubi", now=at))
        # Hours booked the day after change the panel, not what the earlier file says about itself.
        self.store.add_to_sprint("Sprint7", "PROJ-1")
        self.store.add_manual("PROJ-1", ts("2026-11-27T10:00"), 60)
        self.on(2026, 11, 27)
        self.assertEqual(sprint.panel_state(self.store, {})["sprint"]["metrics"]["seconds"], 3600)
        self.assertRegex(review.as_of(), r"^產生於 \d{4}-\d\d-\d\d \d\d:\d\d，")


class RemindDryRun(unittest.TestCase):
    def test_F4_13_a_dry_run_does_not_note_the_event_as_sent(self):
        home = tempfile.TemporaryDirectory()
        data = os.path.join(home.name, "Library", "Application Support", "cubi", "sprint")
        store = Store(data)
        store.new_sprint("Sprint7", "", "2026-11-16", "2026-11-29")
        store.save()
        saved = {k: os.environ.get(k) for k in ("HOME", "CUBI_SPRINT_DIR", "CUBI_RENDER", "CUBI_CLAUDE_SESSIONS")}
        os.environ.update(HOME=home.name, CUBI_RENDER="1", CUBI_CLAUDE_SESSIONS=home.name)
        os.environ.pop("CUBI_SPRINT_DIR", None)

        def tick(when):
            out, real = io.StringIO(), sys.stdin
            sys.stdin = io.StringIO(json.dumps({"now": ts(when), "sessions": []}))
            try:
                with contextlib.redirect_stdout(out):
                    sprint.main(["sprint.py", "tick"])
            finally:
                sys.stdin = real
            return [e["marker"] for e in json.loads(out.getvalue())["calendar"]]
        try:
            self.assertEqual(tick("2026-11-26T08:00:00"), ["sprint:review:Sprint7"])
            os.environ.pop("CUBI_RENDER")
            # An hour later, for real: it still goes out, as if for the first time, then stops.
            self.assertEqual(tick("2026-11-26T09:00:00"), ["sprint:review:Sprint7"])
            self.assertEqual(tick("2026-11-26T09:05:00"), ["sprint:review:Sprint7"])
            self.assertEqual(tick("2026-11-26T09:11:00"), [])
        finally:
            for k, v in saved.items():
                if v is None:
                    os.environ.pop(k, None)
                else:
                    os.environ[k] = v
            home.cleanup()


if __name__ == "__main__":
    unittest.main()
