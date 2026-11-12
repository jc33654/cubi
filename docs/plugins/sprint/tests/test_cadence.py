"""F1: the two-week rhythm. Case numbers are the PRD's (docs/prd/sprint-phase1.md)."""
import contextlib
import io
import json
import os
import sys
import tempfile
import unittest
from datetime import date, datetime

import cadence
import review
import sprint
from store import Store


def ts(text):
    return datetime.fromisoformat(text).timestamp()


class CadenceRules(unittest.TestCase):
    def test_F1_4_F1_9_the_next_label(self):
        for label, following in (("Sprint7", "Sprint8"), ("Sprint09", "Sprint10"), ("S7-2", "S7-3"), ("Sprint99", "Sprint100"),
                                 ("Sprint007", "Sprint008"), ("7", "8"), ("release-a", ""), ("Sprint7b", ""), ("", ""), (None, "")):
            with self.subTest(label=label):
                self.assertEqual(cadence.next_label(label), following)

    def test_F1_1_the_next_sprint_starts_the_monday_after_and_runs_fourteen_days(self):
        self.assertEqual(cadence.next_sprint({"label": "Sprint7", "end": "2026-11-29"}), {"label": "Sprint8", "start": "2026-11-30", "end": "2026-12-13"})
        # An older sprint that ends on its Friday: still the Monday after.
        self.assertEqual(cadence.next_sprint({"label": "Sprint6", "end": "2026-11-13"})["start"], "2026-11-16")
        self.assertIsNone(cadence.next_sprint({"label": "Sprint7"}))
        self.assertIsNone(cadence.next_sprint(None))

    def test_review_and_planning_days_are_the_last_weeks_thursday_and_friday(self):
        days = lambda s: (cadence.review_day(s), cadence.planning_day(s))   # noqa: E731
        self.assertEqual(days({"start": "2026-11-16", "end": "2026-11-29"}), (date(2026, 11, 26), date(2026, 11, 27)))
        # F4-10: ends on a Friday (an older sprint): the day before, and that Friday.
        self.assertEqual(days({"start": "2026-11-02", "end": "2026-11-13"}), (date(2026, 11, 12), date(2026, 11, 13)))
        # F4-14: ended by hand on a Tuesday: both fall back to that day; no end: neither.
        self.assertEqual(days({"start": "2026-11-16", "end": "2026-11-24"}), (date(2026, 11, 24), date(2026, 11, 24)))
        self.assertEqual(days({"start": "2026-11-27", "end": "2026-11-29"}), (date(2026, 11, 27), date(2026, 11, 27)))
        self.assertEqual(days({"start": "2026-11-16"}), (None, None))

    def test_F1_13_F1_14_the_period_counted_from_the_anchor(self):
        self.assertEqual(cadence.period_at("2026-11-02", date(2026, 11, 12)), {"start": "2026-11-02", "end": "2026-11-15"})
        self.assertEqual(cadence.period_at("2026-11-02", date(2026, 11, 16)), {"start": "2026-11-16", "end": "2026-11-29"})
        self.assertIsNone(cadence.period_at("2026-11-16", date(2026, 11, 12)))   # still ahead
        self.assertIsNone(cadence.period_at("", date(2026, 11, 12)))
        p = cadence.period_at("2025-11-03", date(2026, 1, 7))                   # across the new year
        start, end = date.fromisoformat(p["start"]), date.fromisoformat(p["end"])
        self.assertEqual((start.weekday(), (end - start).days), (0, 13))
        self.assertTrue(start <= date(2026, 1, 7) <= end)

    def test_F1_6_the_ideal_line_falls_on_workdays_and_is_zero_from_the_last_one(self):
        rows = [{"estimate": 9, "done": False, "doneAt": None}]
        line = {b["date"]: b["ideal"] for b in review.burndown({"start": "2026-11-16", "end": "2026-11-29"}, rows, today=date(2026, 11, 1))}
        self.assertEqual(line["2026-11-16"], 9)
        self.assertEqual(line["2026-11-20"], 5)                                   # first Friday: 4 of 9 steps down
        self.assertEqual((line["2026-11-21"], line["2026-11-22"]), (5, 5))       # the weekend holds it
        self.assertEqual(line["2026-11-23"], 4)
        self.assertEqual((line["2026-11-27"], line["2026-11-28"], line["2026-11-29"]), (0, 0, 0))
        # A sprint that starts on a weekend has everything left until its first workday.
        line = [b["ideal"] for b in review.burndown({"start": "2026-11-14", "end": "2026-11-17"}, rows, today=date(2026, 11, 1))]
        self.assertEqual(line, [9, 9, 9, 0])
        self.assertEqual([b["ideal"] for b in review.burndown({"start": "2026-11-14", "end": "2026-11-15"}, rows, today=date(2026, 11, 1))], [9, 9])


class CadenceActions(unittest.TestCase):
    def setUp(self):
        self.dir = tempfile.TemporaryDirectory()
        self.store = Store(self.dir.name)
        self.store.config.update(projectKey="PROJ", site="jira.example")
        self.real_today = cadence.today
        self.on(2026, 11, 27)   # the Friday Sprint7's planning falls on
        self.store.new_sprint("Sprint7", "", "2026-11-16", "2026-11-29")
        self.store.add_to_sprint("Sprint7", "PROJ-1")
        self.store.ticket("PROJ-1").update(summary="甲", estimate=1.0)

    def tearDown(self):
        cadence.today = self.real_today
        self.store.close()
        self.dir.cleanup()

    def on(self, *day):
        cadence.today = lambda: date(*day)

    def tick(self, when):
        return sprint.tick(self.store, {"now": ts(when), "sessions": []})

    def test_F1_1_the_panel_proposes_the_next_sprint_until_it_exists(self):
        state = sprint.panel_state(self.store, {})
        self.assertEqual(state["nextSprint"], {"label": "Sprint8", "start": "2026-11-30", "end": "2026-12-13"})
        state = sprint.sprint_new(self.store, state["nextSprint"])
        self.assertIsNone(state["nextSprint"])

    def test_F1_2_F1_3_F1_10_made_ahead_it_waits_then_tick_switches_once(self):
        state = sprint.sprint_new(self.store, {"label": "Sprint8", "start": "2026-11-30", "end": "2026-12-13"})
        self.assertEqual(state["current"], "Sprint7")
        self.assertEqual([(s["label"], s["waiting"]) for s in state["sprints"]], [("Sprint7", False), ("Sprint8", True)])
        self.tick("2026-11-29T23:59:00")
        self.assertEqual(self.store.sprints["current"], "Sprint7")
        self.tick("2026-11-30T00:00:01")
        self.assertEqual(self.store.sprints["current"], "Sprint8")
        sprint.sprint_select(self.store, {"label": "Sprint7"})
        for when in ("2026-11-30T00:01:00", "2026-12-01T09:00:00", "2026-12-13T23:00:00"):
            self.tick(when)
        self.assertEqual(self.store.sprints["current"], "Sprint7")

    def test_F1_11_cubi_started_after_the_first_day_switches_on_its_first_tick(self):
        sprint.sprint_new(self.store, {"label": "Sprint8", "start": "2026-11-30", "end": "2026-12-13"})
        self.tick("2026-12-03T14:00:00")
        self.assertEqual(self.store.sprints["current"], "Sprint8")

    def test_only_a_sprint_made_ahead_waits(self):
        # Made on or after its first day, or without dates: current right away, as before.
        self.on(2026, 11, 30)
        self.assertEqual(sprint.sprint_new(self.store, {"label": "Sprint8", "start": "2026-11-30", "end": "2026-12-13"})["current"], "Sprint8")
        self.assertEqual(sprint.sprint_new(self.store, {"label": "Spike"})["current"], "Spike")
        # Sprints that were there before this rule are never switched to on their own.
        self.store.new_sprint("Sprint9", "", "2026-12-14", "2026-12-27")
        sprint.sprint_select(self.store, {"label": "Sprint8"})
        self.tick("2026-12-15T10:00:00")
        self.assertEqual(self.store.sprints["current"], "Sprint8")

    def test_F1_8_dates_may_not_cross_another_sprint(self):
        sprint.sprint_new(self.store, {"label": "Sprint8", "start": "2026-11-30", "end": "2026-12-13"})
        with self.assertRaisesRegex(ValueError, "和 Sprint8（2026-11-30 – 2026-12-13）重疊"):
            sprint.sprint_update(self.store, {"label": "Sprint7", "end": "2026-11-30"})
        with self.assertRaisesRegex(ValueError, "和 Sprint7"):
            sprint.sprint_new(self.store, {"label": "Sprint9", "start": "2026-11-29", "end": "2026-12-12"})
        self.assertNotIn("Sprint9", self.store.sprints["sprints"])
        self.assertEqual(self.store.sprint("Sprint7")["end"], "2026-11-29")
        # Next to each other is fine; so is changing a sprint's own dates within its room.
        sprint.sprint_update(self.store, {"label": "Sprint7", "start": "2026-11-17"})
        for bad, why in (({"end": "2026-11-01"}, "結束日不能早於開始日"), ({"start": "11/16"}, "開始日期格式不對"), ({"end": "soon"}, "結束日期格式不對")):
            with self.assertRaisesRegex(ValueError, why):
                sprint.sprint_update(self.store, {"label": "Sprint7", **bad})

    def test_F1_5_weekend_hours_count_and_capacity_does_not_move(self):
        before = sprint.panel_state(self.store, {})["sprint"]["capacity"]["workdays"]
        self.store.add_manual("PROJ-1", ts("2026-11-28T10:00"), 90)   # the second Saturday
        s = sprint.panel_state(self.store, {})["sprint"]
        self.assertEqual(s["tickets"][0]["seconds"], 5400)
        self.assertEqual((before, s["capacity"]["workdays"]), (10, 10))

    def test_F1_16_a_stretch_across_two_sprints_is_split_by_overlap(self):
        self.store.new_sprint("Sprint8", "", "2026-11-30", "2026-12-13")
        self.store.add_to_sprint("Sprint8", "PROJ-1")
        self.store.add_manual("PROJ-1", ts("2026-11-29T23:30"), 60)
        for label in ("Sprint7", "Sprint8"):
            since, until = review.sprint_range(self.store.sprint(label))
            self.assertEqual(self.store.hours_by_key(since, until)["PROJ-1"]["total"], 1800, label)

    def test_F1_7_work_with_no_ticket_follows_the_sprint_made_afterwards(self):
        self.on(2026, 11, 30)   # Monday; Sprint8 not made yet
        state = sprint.time_add(self.store, {"start": "2026-11-30T10:00", "minutes": 60, "note": "補記的會", "kind": "會議"})
        self.assertEqual([m["note"] for m in state["sprint"]["other"]], ["補記的會"])   # nowhere else to go yet
        state = sprint.sprint_new(self.store, {"label": "Sprint8", "start": "2026-11-30", "end": "2026-12-13"})
        self.assertEqual((state["current"], [m["note"] for m in state["sprint"]["other"]]), ("Sprint8", ["補記的會"]))
        self.assertEqual(state["sprint"]["metrics"]["otherSeconds"], 3600)
        self.assertEqual({h["label"]: h["seconds"] for h in state["history"]}, {"Sprint7": 0, "Sprint8": 3600})
        self.assertEqual(self.store.other_work("Sprint7"), [])
        md = review.markdown(self.store.sprint("Sprint8"), [], review.metrics([], self.store.other_work("Sprint8")))
        self.assertIn("沒有單號的工作 1h00m", md)

    def test_F1_12_time_no_sprint_holds_goes_by_the_label_it_was_written_with(self):
        self.store.new_sprint("Sprint6", "", "2026-11-02", "2026-11-13")
        self.store.add_manual(None, ts("2026-11-14T10:00"), 30, "會議", "週六的會", sprint="Sprint6")
        self.assertEqual([m["note"] for m in self.store.other_work("Sprint6")], ["週六的會"])
        self.assertEqual(self.store.other_work("Sprint7"), [])

    def test_F1_13_dates_are_proposed_for_a_sprint_that_has_none(self):
        self.on(2026, 11, 12)
        self.assertIsNone(sprint.panel_state(self.store, {})["period"])           # Sprint7 has dates
        with tempfile.TemporaryDirectory() as d:
            fresh = Store(d)
            self.assertEqual(sprint.panel_state(fresh, {})["period"], {"start": "2026-11-02", "end": "2026-11-15"})   # no sprint at all
            fresh.new_sprint("Sprint6")
            self.assertEqual(sprint.panel_state(fresh, {})["period"], {"start": "2026-11-02", "end": "2026-11-15"})
            self.assertEqual(fresh.sprint("Sprint6")["start"], "")                # proposed, not saved
            fresh.config["cadenceAnchor"] = "2026-11-16"                           # F1-14: still ahead
            self.assertIsNone(sprint.panel_state(fresh, {})["period"])
            fresh.config["cadenceAnchor"] = ""
            self.assertIsNone(sprint.panel_state(fresh, {})["period"])
            fresh.close()

    def test_the_anchor_is_a_monday_or_nothing(self):
        for bad in ("2026-11-03", "11/02", "2026-11-2", "soon"):
            with self.assertRaisesRegex(ValueError, "節奏錨點"):
                sprint.config_set(self.store, {"cadenceAnchor": bad})
        self.assertEqual(sprint.config_set(self.store, {"cadenceAnchor": " 2026-11-16 "})["config"]["cadenceAnchor"], "2026-11-16")
        self.assertEqual(sprint.config_set(self.store, {"cadenceAnchor": ""})["config"]["cadenceAnchor"], "")

    def test_F1_15_the_friday_end_is_pointed_out_once(self):
        self.store.new_sprint("Sprint6", "", "2026-11-02", "2026-11-13")
        hints = sprint.panel_state(self.store, {})["hints"]
        self.assertEqual([h["id"] for h in hints], ["weekendGap:Sprint6"])
        self.assertIn("2026-11-15（週日）", hints[0]["text"])
        # Reading the state does not use it up (the command line and review sessions read it too)…
        self.assertEqual(len(sprint.panel_state(self.store, {})["hints"]), 1)
        # …the panel saying it was shown does.
        sprint.hint_seen(self.store, {"id": "weekendGap:Sprint6"})
        self.assertEqual(sprint.panel_state(self.store, {})["hints"], [])
        for bad in ("weekendGap:Nope", "other:Sprint6", "x"):
            with self.assertRaisesRegex(ValueError, "沒有這個提示"):
                sprint.hint_seen(self.store, {"id": bad})
        # Sprint7 ends on a Sunday: nothing to say about it, with or without a Sprint8 after it.
        self.store.new_sprint("Sprint8", "", "2026-11-30", "2026-12-13")
        self.assertEqual(sprint.panel_state(self.store, {})["hints"], [])


class CadenceDryRun(unittest.TestCase):
    """A render of the real data shows the hint without using it up (nothing is saved)."""

    def test_F1_15_a_dry_run_does_not_use_up_the_hint(self):
        home = tempfile.TemporaryDirectory()
        data = os.path.join(home.name, "Library", "Application Support", "cubi", "sprint")
        store = Store(data)
        store.new_sprint("Sprint6", "", "2026-11-02", "2026-11-13")
        store.new_sprint("Sprint7", "", "2026-11-16", "2026-11-29")
        store.save()
        saved = {k: os.environ.get(k) for k in ("HOME", "CUBI_SPRINT_DIR", "CUBI_RENDER")}
        os.environ.update(HOME=home.name, CUBI_RENDER="1")
        os.environ.pop("CUBI_SPRINT_DIR", None)

        def run(action, payload):
            out, real = io.StringIO(), sys.stdin
            sys.stdin = io.StringIO(json.dumps(payload))
            try:
                with contextlib.redirect_stdout(out):
                    sprint.main(["sprint.py", action])
            finally:
                sys.stdin = real
            return json.loads(out.getvalue())

        def hints():
            return [h["id"] for h in run("panel.state", {})["hints"]]
        try:
            run("hint.seen", {"id": "weekendGap:Sprint6"})
            self.assertEqual(hints(), ["weekendGap:Sprint6"])      # a render shows it, and it stays to be said
            os.environ.pop("CUBI_RENDER")
            run("hint.seen", {"id": "weekendGap:Sprint6"})
            self.assertEqual(hints(), [])
        finally:
            for k, v in saved.items():
                if v is None:
                    os.environ.pop(k, None)
                else:
                    os.environ[k] = v
            home.cleanup()


if __name__ == "__main__":
    unittest.main()
