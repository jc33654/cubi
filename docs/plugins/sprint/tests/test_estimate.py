"""F2: an estimate changed in the panel is written to Jira. Case numbers are the PRD's."""
import fcntl
import os
import tempfile
import unittest
from datetime import datetime

import common
import sprint
import tickets
from jira import JiraError
from store import Store


IN_SPRINT = datetime.fromisoformat("2026-11-18T10:00").timestamp()


class FakeJira:
    """Records what is written; `during` runs while "Jira is being asked"."""

    def __init__(self, during=None, fail=None, fail_read=None):
        self.sent, self.during, self.fail, self.fail_read = [], during, fail, fail_read

    def set_field(self, key, field, value):
        if self.during:
            self.during()
        if self.fail:
            raise self.fail
        self.sent.append((key, field, value))

    def issue(self, key, fields):
        if self.fail_read:
            raise self.fail_read
        value = next((v for k, f, v in reversed(self.sent) if k == key), None)
        return {"key": key, "fields": {"summary": "從 Jira 回讀的摘要", "status": {"name": "進行中", "statusCategory": {"key": "indeterminate"}}, fields[-1]: value}}


class EstimateTests(unittest.TestCase):
    def setUp(self):
        self.dir = tempfile.TemporaryDirectory()
        self.store = Store(self.dir.name)
        self.store.config.update(projectKey="PROJ", site="jira.example", pointsField="customfield_10016")
        self.store.new_sprint("Sprint7", "", "2026-11-16", "2026-11-29")
        self.store.add_to_sprint("Sprint7", "PROJ-1")
        self.store.ticket("PROJ-1").update(summary="甲", estimate=2.0)
        self.store.save()
        self.store = Store(self.dir.name)
        self.real = common.jira

    def tearDown(self):
        common.jira = self.real
        self.store.close()
        self.dir.cleanup()

    def jira(self, **how):
        fake = FakeJira(**how)
        common.jira = lambda store: fake
        return fake

    def row(self, state):
        return next(t for t in state["sprint"]["tickets"] if t["key"] == "PROJ-1")

    def test_F2_1_a_new_estimate_goes_to_jira_and_the_panel_follows(self):
        fake = self.jira()
        before = sprint.panel_state(self.store, {})["sprint"]["capacity"]
        state = sprint.estimate_set(self.store, {"key": "PROJ-1", "value": "3"})
        self.assertEqual(fake.sent, [("PROJ-1", "customfield_10016", 3.0)])
        self.assertEqual((self.row(state)["estimate"], self.row(state)["summary"]), (3.0, "從 Jira 回讀的摘要"))
        self.assertEqual((before["pending"], state["sprint"]["capacity"]["pending"], state["sprint"]["capacity"]["planned"]), (2.0, 3.0, 3.0))
        self.assertNotIn("warnings", [k for k, v in state.items() if k == "warnings" and v])

    def test_F2_2_an_empty_value_clears_it_in_jira_and_here(self):
        fake = self.jira()
        state = sprint.estimate_set(self.store, {"key": "PROJ-1", "value": ""})
        self.assertEqual(fake.sent, [("PROJ-1", "customfield_10016", None)])
        self.assertIsNone(self.row(state)["estimate"])
        self.assertEqual((self.row(state)["category"], state["sprint"]["capacity"]["unestimated"]), ("未估點", 1))
        for empty in (None, "   ", "　"):
            self.store.ticket("PROJ-1")["estimate"] = 2.0
            self.store._taken = self.store._dump()
            self.assertIsNone(self.row(sprint.estimate_set(self.store, {"key": "PROJ-1", "value": empty}))["estimate"])

    def test_F2_3_F2_9_what_counts_as_an_estimate(self):
        for text, value in (("3", 3.0), ("0.5", 0.5), (" 2 ", 2.0), ("１.５", 1.5), ("２", 2.0), ("0.01", 0.01), ("100", 100.0), (4, 4.0), (2.5, 2.5), ("", None), (None, None)):
            self.assertEqual(tickets.parse_estimate(text), value, repr(text))
        for bad in ("0", "0.0", "-1", "abc", "1,5", "1 5", "1e3", "1.", ".5", "+2", "1.2.3", "１，５", "NaN", "inf", 0, -1, float("nan"), float("inf"), True, [3], {"v": 3}):
            with self.subTest(value=bad):
                with self.assertRaisesRegex(ValueError, "估點要是大於 0 的數字"):
                    tickets.parse_estimate(bad)
        fake = self.jira()
        with self.assertRaisesRegex(ValueError, "估點要是大於 0 的數字"):
            sprint.estimate_set(self.store, {"key": "PROJ-1", "value": "0"})
        self.assertEqual(fake.sent, [])

    def test_F2_4_a_refusal_from_jira_is_shown_and_nothing_changes_here(self):
        for failure in (JiraError("PUT /rest/api/3/issue/PROJ-1 → HTTP 403 沒有權限", 403), JiraError("連不上 Jira：timed out")):
            self.jira(fail=failure)
            with self.assertRaisesRegex(JiraError, "403|連不上"):
                sprint.estimate_set(self.store, {"key": "PROJ-1", "value": "3"})
            self.assertEqual(self.store.ticket("PROJ-1")["estimate"], 2.0)
            self.assertEqual(self.store._dump(), self.store._taken)        # nothing to save

    def test_written_but_not_read_back_keeps_the_new_estimate_and_says_so(self):
        self.jira(fail_read=JiraError("連不上 Jira：timed out"))
        state = sprint.estimate_set(self.store, {"key": "PROJ-1", "value": "3"})
        self.assertEqual((self.row(state)["estimate"], self.row(state)["summary"]), (3.0, "甲"))
        self.assertEqual(state["warnings"], ["估點已寫進 Jira，但回讀工單失敗：連不上 Jira：timed out"])

    def test_F2_5_only_a_known_ticket_in_exact_form_is_written(self):
        fake = self.jira()
        for key in ("PROJ-404", "proj-1", "PROJ-1/../PROJ-2", "PROJ-1?x", "PROJ-1#", "PROJ-1 ", ""):
            with self.subTest(key=key):
                with self.assertRaisesRegex(ValueError, "單號格式不對|不認得"):
                    sprint.estimate_set(self.store, {"key": key, "value": "3"})
        self.store.config["pointsField"] = "summary"
        with self.assertRaisesRegex(ValueError, "估點欄位"):
            sprint.estimate_set(self.store, {"key": "PROJ-1", "value": "3"})
        self.assertEqual(fake.sent, [])

    def test_F2_8_F2_10_the_lock_is_free_while_jira_is_asked_and_only_the_estimate_is_touched(self):
        seen = {}

        def meanwhile():
            # What the session card or another panel action does while Jira takes its time.
            with open(os.path.join(self.dir.name, ".lock"), "w") as probe:
                fcntl.flock(probe, fcntl.LOCK_EX | fcntl.LOCK_NB)      # raises if the action still held it
                fcntl.flock(probe, fcntl.LOCK_UN)
            other = Store(self.dir.name)
            seen["entry"] = other.add_manual("PROJ-1", IN_SPRINT, 45, note="同時記的")["id"]
            other.bind("s9", "PROJ-1")
            other.ticket("PROJ-1")["notes"] = "同時改的備註"
            other.save()

        self.jira(during=meanwhile)
        state = sprint.estimate_set(self.store, {"key": "PROJ-1", "value": "3"})
        self.store.save()
        after = Store(self.dir.name)
        try:
            self.assertEqual([m["id"] for m in after.segments["manual"]], [seen["entry"]])
            self.assertEqual(after.bindings["s9"]["keys"], ["PROJ-1"])
            self.assertEqual((after.ticket("PROJ-1")["estimate"], after.ticket("PROJ-1")["notes"]), (3.0, "同時改的備註"))
            self.assertEqual(self.row(state)["seconds"], 2700)
        finally:
            after.close()

    def test_F2_8_a_timeout_leaves_the_files_as_the_other_action_wrote_them(self):
        def meanwhile():
            other = Store(self.dir.name)
            other.add_manual("PROJ-1", IN_SPRINT, 45)
            other.save()

        self.jira(during=meanwhile, fail=JiraError("連不上 Jira：timed out"))
        with self.assertRaises(JiraError):
            sprint.estimate_set(self.store, {"key": "PROJ-1", "value": "3"})
        self.store.close()                                              # what main() does after an error
        after = Store(self.dir.name)
        try:
            self.assertEqual((len(after.segments["manual"]), after.ticket("PROJ-1")["estimate"]), (1, 2.0))
        finally:
            after.close()

    def test_going_away_with_unsaved_changes_is_refused(self):
        self.store.ticket("PROJ-1")["notes"] = "還沒存"
        with self.assertRaisesRegex(RuntimeError, "changed before releasing"):
            self.store.away(lambda: None)

    def test_F2_7_a_dry_run_never_reaches_jira(self):
        made, real = [], common.Jira
        common.Jira = lambda *a: made.append(a)
        saved = {k: os.environ.pop(k, None) for k in ("CUBI_SPRINT_DIR", "CUBI_RENDER")}
        os.environ["CUBI_RENDER"] = "1"
        try:
            with self.assertRaisesRegex(JiraError, "離線渲染不連 Jira"):
                sprint.estimate_set(self.store, {"key": "PROJ-1", "value": "3"})
        finally:
            common.Jira = real
            for k, v in saved.items():
                if v is None:
                    os.environ.pop(k, None)
                else:
                    os.environ[k] = v
        self.assertEqual((made, self.store.ticket("PROJ-1")["estimate"]), ([], 2.0))


class HoursPushTests(unittest.TestCase):
    """F7 (the button): the hours worked on a ticket, written over its actual-hours field."""

    def setUp(self):
        self.dir = tempfile.TemporaryDirectory()
        self.store = Store(self.dir.name)
        self.store.config.update(projectKey="PROJ", site="jira.example", actualHoursField="customfield_20001")
        self.store.new_sprint("Sprint6", "", "2026-11-02", "2026-11-15")
        self.store.new_sprint("Sprint7", "", "2026-11-16", "2026-11-29")
        for label in ("Sprint6", "Sprint7"):
            self.store.add_to_sprint(label, "PROJ-1")
        self.store.ticket("PROJ-1").update(summary="甲", estimate=2.0)
        self.store.ticket("PROJ-2").update(summary="乙")
        self.store.save()
        self.store = Store(self.dir.name)
        self.real = common.jira
        self.fake = FakeJira()
        common.jira = lambda store: self.fake

    def tearDown(self):
        common.jira = self.real
        self.store.close()
        self.dir.cleanup()

    def add(self, when, minutes, key="PROJ-1"):
        self.store.add_manual(key, datetime.fromisoformat(when).timestamp(), minutes)
        self.store.save()
        self.store = Store(self.dir.name)

    def test_F7_1_F7_2_every_sprints_hours_and_the_same_number_each_time(self):
        self.add("2026-11-05T10:00", 90)     # the sprint before
        self.add("2026-11-18T10:00", 120)    # this one
        sprint.hours_push(self.store, {"key": "PROJ-1"})
        sprint.hours_push(self.store, {"key": "PROJ-1"})
        self.assertEqual(self.fake.sent, [("PROJ-1", "customfield_20001", 3.5)] * 2)

    def test_F7_3_fifty_minutes_is_0_83(self):
        self.add("2026-11-18T10:00", 50)
        sprint.hours_push(self.store, {"key": "PROJ-1"})
        self.assertEqual(self.fake.sent[-1][2], 0.83)
        # A session's stretch counts by its share, with the manual hours.
        self.store.segments["sessions"]["s1"] = {"1795000000": {"end": 1795003600, "shares": {"PROJ-1": 50.0, "PROJ-2": 50.0}, "open": False, "name": ""}}
        self.store.save()
        self.store = Store(self.dir.name)
        sprint.hours_push(self.store, {"key": "PROJ-1"})
        self.assertEqual(self.fake.sent[-1][2], 1.33)

    def test_F7_4_nothing_worked_is_refused_before_jira_is_asked(self):
        with self.assertRaisesRegex(ValueError, "還沒有投入時數"):
            sprint.hours_push(self.store, {"key": "PROJ-2"})
        self.assertEqual(self.fake.sent, [])

    def test_F7_5_F7_8_the_field_is_optional_and_only_a_custom_field(self):
        for bad in ("summary", "CUSTOMFIELD_1", "customfield_1 2"):
            with self.assertRaisesRegex(ValueError, "「實際時數欄位」要是 customfield_<數字>"):
                sprint.config_set(self.store, {"actualHoursField": bad})
        self.assertEqual(sprint.config_set(self.store, {"actualHoursField": " customfield_77 "})["config"]["actualHoursField"], "customfield_77")
        self.assertEqual(sprint.config_set(self.store, {"actualHoursField": ""})["config"]["actualHoursField"], "")
        self.store._taken = self.store._dump()
        self.add("2026-11-18T10:00", 60)
        self.store.config["actualHoursField"] = ""
        with self.assertRaisesRegex(ValueError, "設定裡沒有「實際時數欄位」"):
            sprint.hours_push(self.store, {"key": "PROJ-1"})
        self.store.config["actualHoursField"] = "summary"       # stored wrong some other way
        with self.assertRaisesRegex(ValueError, "實際時數欄位"):
            sprint.hours_push(self.store, {"key": "PROJ-1"})
        self.assertEqual(self.fake.sent, [])

    def test_F7_6_a_refusal_from_jira_is_shown(self):
        self.add("2026-11-18T10:00", 60)
        self.fake.fail = JiraError("PUT /rest/api/3/issue/PROJ-1 → HTTP 403 沒有權限", 403)
        with self.assertRaisesRegex(JiraError, "403"):
            sprint.hours_push(self.store, {"key": "PROJ-1"})

    def test_only_a_known_ticket_and_the_lock_is_free_while_jira_is_asked(self):
        self.add("2026-11-18T10:00", 60)
        for key in ("PROJ-404", "proj-1", "PROJ-1/../x", ""):
            with self.assertRaisesRegex(ValueError, "單號格式不對|不認得"):
                sprint.hours_push(self.store, {"key": key})

        def meanwhile():
            with open(os.path.join(self.dir.name, ".lock"), "w") as probe:
                fcntl.flock(probe, fcntl.LOCK_EX | fcntl.LOCK_NB)
                fcntl.flock(probe, fcntl.LOCK_UN)
            other = Store(self.dir.name)
            other.add_manual("PROJ-1", IN_SPRINT, 30, note="同時記的")
            other.save()
        self.fake.during = meanwhile
        state = sprint.hours_push(self.store, {"key": "PROJ-1"})
        self.assertEqual(self.fake.sent, [("PROJ-1", "customfield_20001", 1.0)])       # what was worked when the button was pressed
        self.assertEqual(sorted(m.get("note", "") for m in self.store.segments["manual"]), ["", "同時記的"])
        # Both start at 10:00: the 30 min lie inside the hour and count once (batch 19: was 5400).
        self.assertEqual(next(t for t in state["sprint"]["tickets"] if t["key"] == "PROJ-1")["seconds"], 3600)

    def test_F7_7_a_dry_run_never_reaches_jira(self):
        self.add("2026-11-18T10:00", 60)
        common.jira = self.real
        made, real = [], common.Jira
        common.Jira = lambda *a: made.append(a)
        saved = {k: os.environ.pop(k, None) for k in ("CUBI_SPRINT_DIR", "CUBI_RENDER")}
        os.environ["CUBI_RENDER"] = "1"
        try:
            with self.assertRaisesRegex(JiraError, "離線渲染不連 Jira"):
                sprint.hours_push(self.store, {"key": "PROJ-1"})
        finally:
            common.Jira = real
            for k, v in saved.items():
                if v is None:
                    os.environ.pop(k, None)
                else:
                    os.environ[k] = v
        self.assertEqual(made, [])


if __name__ == "__main__":
    unittest.main()
