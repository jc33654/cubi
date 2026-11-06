import json
import os
import subprocess
import sys
import tempfile
import time
import unittest
from datetime import datetime

import common
import sprint
from store import Store


class CardTests(unittest.TestCase):
    def setUp(self):
        self.dir = tempfile.TemporaryDirectory()
        self.store = Store(self.dir.name)
        self.store.config.update(projectKey="PROJ", site="jira.example")
        self.store.ticket("PROJ-1").update(summary="甲", estimate=1.0)
        self.session = {"id": "s1", "name": "PROJ-1", "cwd": None, "segments": []}

    def tearDown(self):
        self.store.save()
        self.dir.cleanup()

    def test_star_a_ticket(self):
        self.store.new_sprint("Sprint7")
        self.store.add_to_sprint("Sprint7", "PROJ-1")
        rows = sprint.ticket_update(self.store, {"key": "PROJ-1", "starred": True})["sprint"]["tickets"]
        self.assertTrue(rows[0]["starred"])
        rows = sprint.ticket_update(self.store, {"key": "PROJ-1", "starred": False})["sprint"]["tickets"]
        self.assertFalse(rows[0]["starred"])

    def test_work_without_a_ticket_goes_to_the_current_sprint(self):
        with self.assertRaises(ValueError):
            sprint.time_add(self.store, {"start": "2026-11-06T10:00", "minutes": 60, "note": "SOP 會議"})   # no sprint yet
        self.store.new_sprint("Sprint7")
        with self.assertRaises(ValueError):
            sprint.time_add(self.store, {"start": "2026-11-06T10:00", "minutes": 60, "note": "  "})       # says what it was
        sprint.time_add(self.store, {"start": "2026-11-06T10:00", "minutes": 60, "kind": "會議", "note": "SOP 會議"})
        out = sprint.time_add(self.store, {"start": "2026-11-06T11:00", "minutes": 30, "kind": "其他", "note": "面試", "counted": False})
        s = out["sprint"]
        self.assertEqual([(m["note"], m["counted"]) for m in s["other"]], [("SOP 會議", True), ("面試", False)])
        self.assertEqual((s["metrics"]["seconds"], s["metrics"]["meetingSeconds"], s["metrics"]["otherSeconds"]), (3600, 3600, 3600))
        self.assertEqual(s["manual"], [])

    def test_points_push_sends_the_points_worked_out_from_hours(self):
        sent = []

        class FakeJira:
            def set_field(self, key, field, value):
                sent.append((key, field, value))
        self.store.config["actualPointsField"] = "customfield_1"
        self.store.ticket("PROJ-1")["actual"] = 9   # an old override: ignored
        self.store.new_sprint("Sprint7")
        self.store.add_to_sprint("Sprint7", "PROJ-1")
        real, sprint.jira = sprint.jira, lambda store: FakeJira()
        try:
            with self.assertRaises(ValueError):
                sprint.points_push(self.store, {"key": "PROJ-1"})    # nothing worked yet
            self.store.add_manual("PROJ-1", time.time() - 7200, 120)
            sprint.points_push(self.store, {"key": "PROJ-1"})
            # Worked over two sprints: the ticket's field gets all of it, not the current sprint's part.
            ts = lambda d: datetime.fromisoformat(d).timestamp()   # noqa: E731
            self.store.new_sprint("Sprint8", "", "2026-11-16", "2026-11-27")
            self.store.add_to_sprint("Sprint8", "PROJ-1")
            self.store.add_manual("PROJ-1", ts("2026-11-17T09:00"), 240)
            sprint.points_push(self.store, {"key": "PROJ-1"})
        finally:
            sprint.jira = real
        self.assertEqual(sent, [("PROJ-1", "customfield_1", 0.25), ("PROJ-1", "customfield_1", 0.75)])

    def test_work_without_a_ticket_goes_to_the_sprint_of_its_date(self):
        self.store.new_sprint("Sprint7", "", "2026-11-02", "2026-11-13")
        self.store.new_sprint("Sprint8", "", "2026-11-16", "2026-11-27")   # now current
        sprint.time_add(self.store, {"start": "2026-11-13T17:00", "minutes": 30, "note": "上一期最後一天的會"})
        sprint.time_add(self.store, {"start": "2026-12-20T10:00", "minutes": 30, "note": "不在任何一期"})
        self.assertEqual([m["note"] for m in self.store.other_work("Sprint7")], ["上一期最後一天的會"])
        self.assertEqual([m["note"] for m in self.store.other_work("Sprint8")], ["不在任何一期"])

    def test_sync_does_not_keep_asking_for_tickets_jira_does_not_know(self):
        calls = []

        class FakeJira:
            def search(self, jql, fields):
                calls.append("search")
                if "PROJ-2" in jql:
                    raise sprint.JiraError("does not exist", code=400)   # one unknown key fails the batch
                return []

            def issue(self, key, fields):
                calls.append(key)
                if key == "PROJ-2":
                    raise sprint.JiraError("not found", code=404)
                return {"key": key, "fields": {"summary": key, "status": {"name": "待辦", "statusCategory": {"key": "new"}}}}
        self.store.config["jql"] = "labels = {label}"
        self.store.new_sprint("Sprint7")
        for k in ("PROJ-1", "PROJ-2"):
            self.store.add_to_sprint("Sprint7", k)
        real, sprint.jira = sprint.jira, lambda store: FakeJira()
        common.jira, real_common = sprint.jira, common.jira
        try:
            sprint.sprint_sync(self.store, {})
            self.assertTrue(self.store.tickets["PROJ-2"]["notFound"])
            calls.clear()
            sprint.sprint_sync(self.store, {})
        finally:
            sprint.jira, common.jira = real, real_common
        self.assertEqual(calls, ["search", "search"])   # the query, then PROJ-1 alone in one batch

    def test_sync_refreshes_tickets_the_query_does_not_return(self):
        asked = []

        def issue(key, status, cat):
            return {"key": key, "fields": {"summary": key, "status": {"name": status, "statusCategory": {"key": cat}}}}

        class FakeJira:
            def search(self, jql, fields):
                asked.append(jql)
                if jql.startswith("key in"):
                    return [issue("PROJ-9", "進行中", "indeterminate")]
                return [issue("PROJ-1", "進行中", "indeterminate")]
        self.store.config["jql"] = "labels = {label}"
        self.store.new_sprint("Sprint7")
        self.store.add_to_sprint("Sprint7", "PROJ-9")                      # added by hand, read before categories were kept
        self.store.ticket("PROJ-9").update(summary="舊", status="進行中")
        real, sprint.jira = sprint.jira, lambda store: FakeJira()
        common.jira, real_common = sprint.jira, common.jira
        try:
            rows = sprint.sprint_sync(self.store, {})["sprint"]["tickets"]
        finally:
            sprint.jira, common.jira = real, real_common
        self.assertEqual(asked, ["labels = Sprint7", "key in (PROJ-9)"])
        self.assertEqual({r["key"]: r["statusCategory"] for r in rows}, {"PROJ-9": "indeterminate", "PROJ-1": "indeterminate"})

    def test_every_bound_ticket_has_its_own_unbind_button_on_its_row(self):
        keys = [f"PROJ-{i}" for i in range(1, 7)]
        for k in keys:
            self.store.ticket(k).update(summary=k, estimate=1.0)
        out = sprint.session_info(self.store, {**self.session, "name": " ".join(keys)})
        self.assertEqual([(r["label"], r["action"]["action"], r["action"]["arg"]) for r in out["rows"] if "action" in r],
                         [(k, "session.unbind", k) for k in keys])
        self.assertNotIn("session.unbind", self.actions(out))

    def actions(self, out):
        return [a["action"] for a in out["actions"]]

    def test_card_lists_eight_tickets_and_counts_the_rest(self):
        keys = [f"PROJ-{i}" for i in range(1, 11)]
        def labels(out):
            return [r["label"] if isinstance(r, dict) else r[0] for r in out["rows"]]
        out = sprint.session_info(self.store, {**self.session, "name": " ".join(keys)})
        self.assertEqual(labels(out), keys[:8] + ["還有", "今日"])
        self.assertIn("2 張沒列出", out["rows"][8]["value"])
        sprint.timer_start(self.store, {**self.session, "name": " ".join(keys)})
        out = sprint.session_info(self.store, {**self.session, "name": " ".join(keys)})
        self.assertEqual(labels(out), keys[:7] + ["還有", "今日", "計時中"])   # still within cubi's 10 rows

    def test_bindings_overview_unbinds_any_session(self):
        worked = [{"start": time.time() - 600, "end": time.time(), "open": False}]
        sprint.session_info(self.store, {**self.session, "name": "PROJ-1 PROJ-2", "segments": worked})
        sprint.session_info(self.store, {**self.session, "id": "s2", "name": "PROJ-3", "segments": worked})
        state = sprint.panel_state(self.store, {})
        self.assertEqual([(b["sid"], b["keys"]) for b in state["bindings"]], [("s1", ["PROJ-1", "PROJ-2"]), ("s2", ["PROJ-3"])])
        state = sprint.session_unbind(self.store, {"sid": "s1", "key": "PROJ-2", "session": {**self.session, "id": "s2", "name": "PROJ-3"}})
        self.assertEqual([(b["sid"], b["keys"]) for b in state["bindings"]], [("s1", ["PROJ-1"]), ("s2", ["PROJ-3"])])
        with self.assertRaises(ValueError):
            sprint.session_unbind(self.store, {"sid": "nope", "key": "PROJ-1"})

    def test_offline_render_without_test_data_writes_nothing(self):
        home = tempfile.TemporaryDirectory()
        self.addCleanup(home.cleanup)
        env = {k: v for k, v in os.environ.items() if k not in ("CUBI_SPRINT_DIR", "CUBI_RENDER")}

        def run(extra):
            return subprocess.run([sys.executable, sprint.__file__, "session.info"], input=json.dumps(self.session),
                                  capture_output=True, text=True, env={**env, "HOME": home.name, **extra})
        self.assertEqual(json.loads(run({"CUBI_RENDER": "1"}).stdout)["rows"][0]["label"], "PROJ-1")   # drawn all the same
        self.assertFalse(os.path.exists(os.path.join(home.name, "Library", "Application Support", "cubi", "sprint", "bindings.json")))
        run({})
        self.assertTrue(os.path.exists(os.path.join(home.name, "Library", "Application Support", "cubi", "sprint", "bindings.json")))

    def test_offline_render_on_real_data_never_reaches_jira_or_writes_reviews(self):
        made = []
        real = common.Jira
        common.Jira = lambda *a: made.append(a)
        saved = {k: os.environ.pop(k, None) for k in ("CUBI_SPRINT_DIR", "CUBI_RENDER")}
        os.environ["CUBI_RENDER"] = "1"
        try:
            self.assertTrue(sprint.dry_run())
            with self.assertRaisesRegex(sprint.JiraError, "離線渲染不連 Jira"):
                sprint.jira(self.store)
            with self.assertRaisesRegex(ValueError, "離線渲染不寫回顧檔"):
                sprint.review_dir(self.store)
            os.environ["CUBI_SPRINT_DIR"] = self.dir.name   # test data: business as usual
            self.assertFalse(sprint.dry_run())
            sprint.jira(self.store)
        finally:
            common.Jira = real
            for k, v in saved.items():
                os.environ.pop(k, None)
                if v is not None:
                    os.environ[k] = v
        self.assertEqual(len(made), 1)   # only the test-data run built a client

    def test_pause_stays_after_the_last_ticket_is_unbound(self):
        sprint.timer_start(self.store, self.session)
        out = sprint.session_unbind(self.store, {**self.session, "input": "PROJ-1"})
        self.store.bindings["s1"]["removed"] = ["PROJ-1"]
        out = sprint.session_info(self.store, self.session)
        self.assertIn("timer.stop", self.actions(out))
        self.assertTrue(any((r.get("label") if isinstance(r, dict) else r[0]) == "計時中" for r in out["rows"]))

    def test_with_every_ticket_unbound_the_timer_says_it_books_nothing(self):
        sprint.timer_start(self.store, self.session)
        sprint.session_unbind(self.store, {"sid": "s1", "key": "PROJ-1"})    # from the panel's overview
        self.store.timer("s1")["start"] -= 9 * 3600                         # and long forgotten
        out = sprint.session_info(self.store, self.session)
        timing = next(r for r in out["rows"] if isinstance(r, dict) and r["label"] == "計時中")
        self.assertEqual((timing["value"], timing["tone"]), ("超過 8 小時，忘了停？；單都解除了，停下來不會記", "danger"))
        stop = next(a for a in out["actions"] if a["action"] == "timer.stop")
        self.assertEqual(stop["label"], "停止計時（沒綁單，不記）")
        self.assertEqual(sprint.panel_state(self.store, {})["timers"][0]["keys"], [])

    def test_a_session_that_only_timed_shows_in_the_overview(self):
        self.store.new_sprint("Sprint7", "", "2026-11-02", "2026-11-13")
        self.store.bind("t1", "PROJ-1")
        m = self.store.add_manual("PROJ-1", datetime.fromisoformat("2026-11-05T10:00").timestamp(), 60, kind="計時")
        m.update(session="t1", shares={"PROJ-1": 100.0})
        self.assertEqual([b["sid"] for b in sprint.panel_state(self.store, {})["bindings"]], ["t1"])

    def test_overview_lists_only_sessions_active_in_the_sprint(self):
        self.store.new_sprint("Sprint7", "", "2026-11-02", "2026-11-13")
        def ts(d):
            return datetime.fromisoformat(d).timestamp()
        for sid, name, start in (("old", "PROJ-1 上一期", "2026-10-20T10:00"), ("now", "PROJ-1 這一期", "2026-11-05T10:00"), ("idle", "PROJ-1 沒動過", None)):
            sess = {"id": sid, "name": name, "cwd": None, "segments": [{"start": ts(start), "end": ts(start) + 600, "open": False}] if start else []}
            self.store.record_segments(sess, self.store.shares(self.store.binding(sess)))
        self.assertEqual([b["sid"] for b in sprint.panel_state(self.store, {})["bindings"]], ["now"])
        # The session the panel was opened from is listed even before it did anything.
        here = {"id": "idle", "name": "PROJ-1 沒動過", "cwd": None, "segments": []}
        self.assertEqual(sorted(b["sid"] for b in sprint.panel_state(self.store, {"session": here})["bindings"]), ["idle", "now"])

    def test_stop_from_the_panel_without_a_sid_is_a_warning(self):
        out = sprint.timer_stop(self.store, {})
        self.assertIn("要停哪個計時？", out["warnings"])

    def test_claude_session_ids_reads_only_json(self):
        with tempfile.TemporaryDirectory() as d:
            for name, body in (("1.json", {"sessionId": "aa"}), ("2.json", {"other": 1}), ("3.json", "not an object"), ("1.abc.key", {"sessionId": "zz"}),
                               ("5.json", {"sessionId": "mine", "pid": os.getpid()}), ("6.json", {"sessionId": "dead", "pid": 2 ** 22 + 12345})):
                with open(os.path.join(d, name), "w") as f:
                    json.dump(body, f)
            with open(os.path.join(d, "4.json"), "w") as f:
                f.write("{broken")
            os.environ["CUBI_CLAUDE_SESSIONS"] = d
            try:
                # A file without a pid is trusted; one whose pid is gone (a crashed Claude Code) is not.
                self.assertEqual(sprint.claude_session_ids(), {"aa", "mine"})
            finally:
                del os.environ["CUBI_CLAUDE_SESSIONS"]


if __name__ == "__main__":
    unittest.main()
