"""F7 (on its own): hours written to Jira by tick after a timer stops or a manual stretch is
added, changed or removed. Case numbers are the PRD's."""
import fcntl
import os
import tempfile
import unittest
from datetime import datetime
from unittest import mock

import autopush
import common
import sprint
from jira import JiraError
from store import Store


def ts(text):
    return datetime.fromisoformat(text).timestamp()


NOW = ts("2026-11-18T15:00:00")
SESSION = {"id": "s1", "name": "PROJ-1 PROJ-2", "cwd": None, "segments": []}


class FakeJira:
    """Stands in for autopush.Jira: counts requests, fails as told, takes `seconds` each (on the
    fake clock), runs `during` while "asked"."""
    calls, fail, seconds, during, timeout = [], {}, 0, None, None

    def __init__(self, site, netrc, timeout=15):
        FakeJira.timeout = timeout

    def set_field(self, key, field, value):
        FakeJira.calls.append((key, field, value))
        Clock.now += FakeJira.seconds
        if FakeJira.during:
            FakeJira.during()
        if key in FakeJira.fail:
            raise FakeJira.fail[key]


class Clock:
    now = 0.0


class AutoPushTests(unittest.TestCase):
    def setUp(self):
        self.dir = tempfile.TemporaryDirectory()
        self.store = Store(self.dir.name)
        self.store.config.update(projectKey="PROJ", site="jira.example", actualHoursField="customfield_20001", autoPushHours=True)
        self.store.new_sprint("Sprint7", "", "2026-11-16", "2026-11-29")
        for i in range(1, 13):
            self.store.add_to_sprint("Sprint7", f"PROJ-{i}")
            self.store.ticket(f"PROJ-{i}").update(summary=f"單 {i}", estimate=1.0)
        FakeJira.calls, FakeJira.fail, FakeJira.seconds, FakeJira.during = [], {}, 0, None
        Clock.now = 0.0
        for target, value in (("autopush.Jira", FakeJira), ("autopush.time.monotonic", lambda: Clock.now), ("worklog.time.time", lambda: NOW)):
            patch = mock.patch(target, value)
            patch.start()
            self.addCleanup(patch.stop)
        self.reopen()

    def tearDown(self):
        self.store.close()
        self.dir.cleanup()

    def reopen(self):
        """Save and load again, the way each action is its own process."""
        self.store.save()
        self.store = Store(self.dir.name)

    def waiting(self):
        return autopush.waiting(self.store)

    def tick(self):
        out = sprint.tick(self.store, {"now": NOW, "sessions": []})
        self.reopen()
        return out

    # ---------- what makes a ticket wait ----------

    def test_F7_9_stopping_a_timer_makes_its_tickets_wait_and_asks_jira_nothing(self):
        sprint.session_info(self.store, SESSION)
        self.store.timer_start("s1", NOW - 1800)
        out = sprint.timer_stop(self.store, SESSION)
        self.assertNotIn("error", out)
        self.assertEqual((self.waiting(), FakeJira.calls), (["PROJ-1", "PROJ-2"], []))
        # From the panel too; a stop that books nothing makes nothing wait.
        self.store.timer_start("s1", NOW - 600)
        sprint.timer_stop(self.store, {"sid": "s1"})
        self.assertEqual(self.waiting(), ["PROJ-1", "PROJ-2"])
        for key in ("PROJ-1", "PROJ-2"):
            del self.store.tickets[key]["hoursPush"]
        self.store.timer_start("s1", NOW - 20)                       # under a minute: not booked
        sprint.timer_stop(self.store, {"sid": "s1"})
        self.assertEqual(self.waiting(), [])

    def test_F7_11_adding_changing_and_removing_a_manual_stretch_each_make_its_ticket_wait(self):
        sprint.time_add(self.store, {"key": "PROJ-3", "minutes": 60})
        self.assertEqual(self.waiting(), ["PROJ-3"])
        entry = self.store.segments["manual"][-1]
        for change in ({"minutes": 90}, {"start": "2026-11-17T09:00"}, {"kind": "會議"}):
            del self.store.tickets["PROJ-3"]["hoursPush"]
            sprint.time_update(self.store, {"id": entry["id"], **change})
            self.assertEqual(self.waiting(), ["PROJ-3"], change)
        del self.store.tickets["PROJ-3"]["hoursPush"]
        sprint.time_update(self.store, {"id": entry["id"], "minutes": 90})   # nothing changed: nothing to write
        self.assertEqual(self.waiting(), [])
        sprint.time_remove(self.store, {"id": entry["id"]})
        self.assertEqual(self.waiting(), ["PROJ-3"])
        # A timer's stretch split over two tickets: both. Work with no ticket: none.
        split = self.store.add_manual("PROJ-4", NOW - 3600, 30)
        split.update(session="s9", shares={"PROJ-4": 50.0, "PROJ-5": 50.0})
        sprint.time_update(self.store, {"id": split["id"], "minutes": 45})
        sprint.time_add(self.store, {"start": "2026-11-18T10:00", "minutes": 30, "note": "面試", "item": "招募", "newItem": True})
        self.assertEqual(self.waiting(), ["PROJ-3", "PROJ-4", "PROJ-5"])

    def test_F7_12_F7_16_switched_off_or_without_a_field_nothing_waits_and_tick_writes_nothing(self):
        for config in ({"autoPushHours": False}, {"actualHoursField": ""}, {"actualHoursField": "summary"}):
            self.store.config.update(actualHoursField="customfield_20001", autoPushHours=True)
            self.store.config.update(config)
            sprint.time_add(self.store, {"key": "PROJ-1", "minutes": 60})
            sprint.session_info(self.store, SESSION)
            self.store.timer_start("s1", NOW - 1800)
            sprint.timer_stop(self.store, SESSION)
            self.assertEqual(self.waiting(), [], config)
        # Already waiting when it was switched off: stays as it is, unwritten.
        self.store.config.update(actualHoursField="customfield_20001", autoPushHours=True)
        sprint.time_add(self.store, {"key": "PROJ-1", "minutes": 60})
        self.store.config["autoPushHours"] = False
        self.tick()
        self.assertEqual((self.waiting(), FakeJira.calls), (["PROJ-1"], []))
        # F7-16: only a session's own stretches growing, tick after tick: nothing waits, nothing is asked.
        self.store.config["autoPushHours"] = True
        del self.store.tickets["PROJ-1"]["hoursPush"]
        for i in range(3):
            growing = {**SESSION, "segments": [{"start": NOW - 600, "end": NOW + i * 60, "open": True}]}
            sprint.tick(self.store, {"now": NOW + i * 60, "sessions": [growing]})
            self.reopen()
        self.assertEqual((self.waiting(), FakeJira.calls), ([], []))

    def test_F7_17_a_ticket_waits_once_and_is_asked_about_once(self):
        for minutes in (30, 45, 60):
            sprint.time_add(self.store, {"key": "PROJ-1", "minutes": minutes})
        self.assertEqual(self.waiting(), ["PROJ-1"])
        self.tick()
        # All three end now: one ticket's same minutes count once (batch 19), so 60 min, not 30+45+60.
        self.assertEqual(FakeJira.calls, [("PROJ-1", "customfield_20001", 1.0)])

    # ---------- tick writes them ----------

    def test_F7_10_tick_writes_the_hours_as_they_are_then_and_the_ticket_stops_waiting(self):
        self.store.add_manual("PROJ-1", ts("2026-11-05T10:00"), 90)             # an earlier sprint's
        sprint.time_add(self.store, {"key": "PROJ-1", "minutes": 120})
        self.reopen()
        self.assertEqual(FakeJira.calls, [])
        out = self.tick()
        self.assertIn("calendar", out)
        self.assertEqual((FakeJira.calls, FakeJira.timeout), ([("PROJ-1", "customfield_20001", 3.5)], autopush.REQUEST_TIMEOUT))
        self.assertEqual(self.waiting(), [])
        self.assertNotIn("hoursPush", self.store.tickets["PROJ-1"])
        self.tick()
        self.assertEqual(len(FakeJira.calls), 1)

    def test_a_ticket_left_with_no_hours_is_written_as_zero(self):
        sprint.time_add(self.store, {"key": "PROJ-1", "minutes": 60})
        sprint.time_remove(self.store, {"id": self.store.segments["manual"][-1]["id"]})
        self.tick()
        self.assertEqual(FakeJira.calls, [("PROJ-1", "customfield_20001", 0.0)])

    def test_F7_13_a_timeout_keeps_the_ticket_waiting_for_the_next_tick(self):
        sprint.time_add(self.store, {"key": "PROJ-1", "minutes": 60})
        FakeJira.fail = {"PROJ-1": JiraError("連不上 Jira：timed out")}
        self.tick()
        self.assertEqual(self.waiting(), ["PROJ-1"])
        state = sprint.panel_state(self.store, {})["hoursPush"]
        self.assertEqual((state["pending"], state["stopped"], state["error"]), (["PROJ-1"], [], "PROJ-1：連不上 Jira：timed out"))
        FakeJira.fail = {}
        self.tick()
        self.assertEqual((self.waiting(), len(FakeJira.calls)), ([], 2))
        self.assertIsNone(sprint.panel_state(self.store, {})["hoursPush"]["error"])
        # A server error or a rate limit is also worth another try.
        for code in (500, 502, 429):
            sprint.time_add(self.store, {"key": "PROJ-1", "minutes": 1})
            FakeJira.fail = {"PROJ-1": JiraError(f"HTTP {code}", code)}
            self.tick()
            self.assertEqual(self.waiting(), ["PROJ-1"], code)
            FakeJira.fail = {}
            self.tick()

    def test_F7_21_one_tickets_unexpected_failure_is_its_own_and_tick_carries_on(self):
        import json
        for i in (1, 2, 3):
            sprint.time_add(self.store, {"key": f"PROJ-{i}", "minutes": 30})
            self.store.tickets[f"PROJ-{i}"]["hoursPush"]["since"] = NOW + i
        self.store.add_manual("PROJ-4", NOW - 7200, 30, calendar=True)
        # Jira (or something in front of it) answered 200 with a page that is not JSON; and worse.
        FakeJira.fail = {"PROJ-1": json.JSONDecodeError("Expecting value", "<html>", 0), "PROJ-2": RuntimeError("boom")}
        session = {**SESSION, "segments": [{"start": NOW - 900, "end": NOW, "open": False}]}
        out = sprint.tick(self.store, {"now": NOW, "sessions": [session]})
        self.reopen()
        kinds = sorted(e["marker"].split(":")[1] for e in out["calendar"])
        self.assertEqual(kinds, ["manual", "review", "s1"])                        # tick's own answer is whole: the review event, the manual stretch, the session's
        self.assertIn("s1", self.store.segments["sessions"])                       # and its own work is stored
        self.assertEqual([c[0] for c in FakeJira.calls], ["PROJ-1", "PROJ-2", "PROJ-3"])   # the round went on past the failures
        self.assertEqual(self.waiting(), ["PROJ-1", "PROJ-2"])                     # both wait for the next tick; the third was written
        state = sprint.panel_state(self.store, {})["hoursPush"]
        self.assertEqual(state["stopped"], [])
        self.assertRegex(state["error"], r"^PROJ-[12]：(JSONDecodeError|RuntimeError): ")
        FakeJira.fail = {}
        self.tick()
        self.assertEqual(self.waiting(), [])

    def test_F7_14_F7_19_a_refusal_stops_the_retries_and_is_kept_for_the_panel(self):
        for code, text in ((403, "Jira 認證失敗（401/403），檢查 netrc 的帳號與 token"), (400, "HTTP 400 Field cannot be set"), (404, "HTTP 404 Issue does not exist")):
            FakeJira.calls = []
            sprint.time_add(self.store, {"key": "PROJ-1", "minutes": 30})
            FakeJira.fail = {"PROJ-1": JiraError(text, code)}
            self.tick()
            self.tick()
            self.assertEqual((self.waiting(), len(FakeJira.calls)), ([], 1), code)        # asked once, not again
            state = sprint.panel_state(self.store, {})["hoursPush"]
            self.assertEqual((state["pending"], state["stopped"], state["error"]), ([], ["PROJ-1"], f"PROJ-1：{text}"))
            # 手動重試: it waits again, and the next tick asks again.
            FakeJira.fail = {}
            state = sprint.hours_retry(self.store, {})["hoursPush"]
            self.assertEqual((state["pending"], state["stopped"]), (["PROJ-1"], []))
            self.tick()
            self.assertEqual((self.waiting(), len(FakeJira.calls), sprint.panel_state(self.store, {})["hoursPush"]["error"]), ([], 2, None))

    def test_new_work_on_a_refused_ticket_lets_it_be_tried_again(self):
        sprint.time_add(self.store, {"key": "PROJ-1", "minutes": 30})
        FakeJira.fail = {"PROJ-1": JiraError("HTTP 403", 403)}
        self.tick()
        self.assertEqual(self.waiting(), [])
        sprint.time_add(self.store, {"key": "PROJ-1", "minutes": 30})
        self.assertEqual(self.waiting(), ["PROJ-1"])

    def test_F7_15_three_tickets_a_tick_and_none_started_after_ten_seconds(self):
        for i in range(1, 11):
            sprint.time_add(self.store, {"key": f"PROJ-{i}", "minutes": 30})
            self.store.tickets[f"PROJ-{i}"]["hoursPush"]["since"] = NOW + i          # the order they came in
        FakeJira.seconds = 4
        self.tick()
        self.assertEqual([c[0] for c in FakeJira.calls], ["PROJ-1", "PROJ-2", "PROJ-3"])
        self.assertEqual((Clock.now, len(self.waiting())), (12.0, 7))               # 3 × 4 s, well inside the hook's 20
        # Slower still (each takes its whole 5 s timeout… and then some): the third is not started.
        FakeJira.calls, FakeJira.seconds, Clock.now = [], 5.5, 0.0
        self.tick()
        self.assertEqual(([c[0] for c in FakeJira.calls], Clock.now), (["PROJ-4", "PROJ-5"], 11.0))
        self.assertEqual(len(self.waiting()), 5)
        self.assertLessEqual(autopush.BUDGET + autopush.REQUEST_TIMEOUT, 15)        # the worst case the PRD allows

    def test_F7_20_the_lock_is_free_while_jira_is_asked_and_what_was_written_meanwhile_stays(self):
        sprint.time_add(self.store, {"key": "PROJ-1", "minutes": 60})
        self.reopen()
        seen = {}

        def meanwhile():
            with open(os.path.join(self.dir.name, ".lock"), "w") as probe:
                fcntl.flock(probe, fcntl.LOCK_EX | fcntl.LOCK_NB)                   # raises if tick still held it
                fcntl.flock(probe, fcntl.LOCK_UN)
            other = Store(self.dir.name)
            # What tick did before asking Jira is already on disk: the session's stretch it was handed.
            seen["tick saved first"] = "s1" in other.segments["sessions"]
            other.add_manual("PROJ-2", NOW - 600, 10, note="同時記的")
            other.tickets["PROJ-2"]["hoursPush"] = {"since": NOW, "pending": True}   # what time.add would have noted
            other.save()
        FakeJira.during = meanwhile
        sprint.tick(self.store, {"now": NOW, "sessions": [{**SESSION, "segments": [{"start": NOW - 900, "end": NOW, "open": False}]}]})
        self.reopen()
        self.assertTrue(seen["tick saved first"])
        self.assertEqual([m.get("note") for m in self.store.segments["manual"]][-1], "同時記的")
        self.assertEqual(self.waiting(), ["PROJ-2"])                                # PROJ-1 written; the one noted meanwhile still waits
        # Its hour; the session's 15 min fall inside that hour, so they add nothing (batch 19: was 1.12).
        self.assertEqual(FakeJira.calls, [("PROJ-1", "customfield_20001", 1.0)])

    def test_F7_18_a_dry_run_notes_nothing_and_asks_nothing(self):
        saved = {k: os.environ.pop(k, None) for k in ("CUBI_SPRINT_DIR", "CUBI_RENDER")}
        os.environ["CUBI_RENDER"] = "1"
        try:
            self.assertTrue(common.dry_run())
            self.store.tickets["PROJ-1"]["hoursPush"] = {"since": NOW, "pending": True}
            self.store.add_manual("PROJ-1", NOW - 3600, 60)
            sprint.tick(self.store, {"now": NOW, "sessions": []})
        finally:
            for k, v in saved.items():
                if v is None:
                    os.environ.pop(k, None)
                else:
                    os.environ[k] = v
        self.assertEqual((FakeJira.calls, self.waiting()), ([], ["PROJ-1"]))

    def test_the_switch_is_on_or_off(self):
        for bad in ("true", 1, "on", None):
            with self.assertRaisesRegex(ValueError, "要是開或關"):
                sprint.config_set(self.store, {"autoPushHours": bad})
        self.assertIs(sprint.config_set(self.store, {"autoPushHours": False})["config"]["autoPushHours"], False)
        self.assertIs(sprint.config_set(self.store, {"autoPushHours": True})["config"]["autoPushHours"], True)
        self.assertEqual(sprint.panel_state(self.store, {})["hoursPush"]["on"], True)
        self.store.config["actualHoursField"] = ""
        self.assertEqual(sprint.panel_state(self.store, {})["hoursPush"]["on"], False)    # the switch alone does nothing


if __name__ == "__main__":
    unittest.main()
