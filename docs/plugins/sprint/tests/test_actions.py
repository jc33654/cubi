"""Every action once through main(), the way cubi runs it: stdin JSON in, stdout JSON out, the
data directory from the environment. Jira is out of reach (the netrc file does not exist)."""
import contextlib
import io
import json
import os
import re
import sys
import tempfile
import unittest

import sprint
from store import Store

SESSION = {"id": "s1", "name": "PROJ-1", "cwd": None, "segments": []}
NO_JIRA = "讀不到"
# How main() words an exception no handler expected.
UNHANDLED = re.compile(r"^[A-Za-z]+(Error|Exception): ")

# action → (payload, what the output must hold, the error it must carry or None)
CASES = {
    "session.info": (SESSION, ("title", "rows", "actions"), None),
    "session.sync": (SESSION, ("rows",), NO_JIRA),
    "session.bind": ({**SESSION, "input": "PROJ-2"}, ("rows",), NO_JIRA),
    "session.unbind": ({**SESSION, "input": "PROJ-1"}, ("rows",), None),
    "session.shares": ({"session": SESSION, "shares": {"PROJ-1": 100}}, ("sprint", "session"), None),
    "tick": ({"now": 1794448000, "sessions": [SESSION]}, ("calendar",), None),
    "panel.state": ({}, ("sprint", "config", "sprints"), None),
    "sprint.new": ({"label": "Sprint8"}, ("sprint",), None),
    "sprint.update": ({"goal": "目標"}, ("sprint",), None),
    "sprint.select": ({"label": "Sprint7"}, ("sprint",), None),
    "sprint.sync": ({}, (), NO_JIRA),
    "ticket.add": ({"key": "PROJ-2"}, (), NO_JIRA),
    "ticket.update": ({"key": "PROJ-1", "starred": True}, ("sprint",), None),
    "ticket.transition": ({"key": "PROJ-1"}, (), NO_JIRA),
    "points.push": ({"key": "PROJ-1"}, (), "實際點數欄位"),
    "time.add": ({"key": "PROJ-1", "start": "2026-11-05T10:00", "minutes": 30}, ("sprint",), None),
    "time.remove": ({"id": "nope"}, ("sprint",), None),
    "review.update": ({"summary": "總結"}, ("sprint",), None),
    "timer.start": (SESSION, ("rows",), None),
    "timer.stop": (SESSION, ("rows",), "沒有在計時"),
    "review.brief": ({}, ("directory", "prompt", "file"), None),
    "review.export": ({}, (), None),
    "config.set": ({"hoursPerPoint": "6"}, ("config",), None),
}


class ActionTests(unittest.TestCase):
    def setUp(self):
        self.dir = tempfile.TemporaryDirectory()
        self.data = os.path.join(self.dir.name, "data")
        self.sessions = os.path.join(self.dir.name, "sessions")
        os.makedirs(self.sessions)
        store = Store(self.data)
        store.config.update(projectKey="PROJ", site="jira.example", netrc=os.path.join(self.dir.name, "no-netrc"),
                            reviewDir=os.path.join(self.dir.name, "reviews"), reviewSessionDir=self.dir.name)
        store.new_sprint("Sprint7", "", "2026-11-02", "2026-11-13")
        store.add_to_sprint("Sprint7", "PROJ-1")
        store.ticket("PROJ-1").update(summary="甲", estimate=1.0)
        store.save()
        self.env = {k: os.environ.get(k) for k in ("CUBI_SPRINT_DIR", "CUBI_CLAUDE_SESSIONS", "CUBI_RENDER")}
        os.environ.update(CUBI_SPRINT_DIR=self.data, CUBI_CLAUDE_SESSIONS=self.sessions)
        os.environ.pop("CUBI_RENDER", None)

    def tearDown(self):
        for k, v in self.env.items():
            if v is None:
                os.environ.pop(k, None)
            else:
                os.environ[k] = v
        self.dir.cleanup()

    def files(self):
        out = {}
        for name in sorted(os.listdir(self.data)):
            if name.endswith(".json"):
                with open(os.path.join(self.data, name), encoding="utf-8") as f:
                    out[name] = f.read()
        return out

    def run_main(self, action, stdin):
        out, real = io.StringIO(), sys.stdin
        sys.stdin = io.StringIO(stdin)
        try:
            with contextlib.redirect_stdout(out), contextlib.redirect_stderr(io.StringIO()):
                code = sprint.main(["sprint.py", action])
        finally:
            sys.stdin = real
        return code, out.getvalue()

    def test_the_table_the_dispatcher_and_the_manifest_list_the_same_actions(self):
        with open(os.path.join(os.path.dirname(os.path.abspath(sprint.__file__)), "manifest.json"), encoding="utf-8") as f:
            manifest = json.load(f)
        self.assertEqual(set(CASES), set(sprint.ACTIONS))
        self.assertEqual(set(manifest["commands"]), set(sprint.ACTIONS))

    def test_every_action_answers_its_smallest_payload(self):
        for action, (payload, keys, error) in CASES.items():
            with self.subTest(action=action):
                self.tearDown()
                self.setUp()
                code, text = self.run_main(action, json.dumps(payload, ensure_ascii=False))
                self.assertEqual(code, 0, text)
                if action in sprint.RAW_ACTIONS:
                    self.assertTrue(os.path.isfile(text.strip()), text)
                    continue
                out = json.loads(text)
                self.assertNotRegex(out.get("error") or "", UNHANDLED)
                if error is None:
                    self.assertNotIn("error", out)
                else:
                    self.assertIn(error, out["error"])
                for k in keys:
                    self.assertIn(k, out)

    def test_an_empty_stdin_is_an_empty_payload(self):
        code, text = self.run_main("panel.state", "")
        self.assertEqual((code, json.loads(text)["current"]), (0, "Sprint7"))

    def test_what_main_refuses(self):
        code, text = self.run_main("no.such.action", "{}")
        self.assertEqual(code, 2)
        self.assertIn("用法", json.loads(text)["error"])
        code, text = self.run_main("panel.state", "{not json")
        self.assertEqual(code, 1)
        self.assertIn("不是 JSON", json.loads(text)["error"])
        code, text = self.run_main("ticket.update", "{}")
        self.assertEqual((code, json.loads(text)["error"]), (0, "缺少欄位 'key'"))

    def test_a_failed_action_leaves_the_files_alone(self):
        before = self.files()
        self.run_main("sprint.sync", "{}")
        self.assertEqual(self.files(), before)

    def test_what_an_action_stores_the_next_one_reads(self):
        self.run_main("time.add", json.dumps({"key": "PROJ-1", "start": "2026-11-05T10:00", "minutes": 90}))
        code, text = self.run_main("panel.state", "{}")
        row = next(t for t in json.loads(text)["sprint"]["tickets"] if t["key"] == "PROJ-1")
        self.assertEqual(row["seconds"], 5400)

    # ---------- what a payload may hold ----------

    def answer(self, action, payload):
        code, text = self.run_main(action, json.dumps(payload, ensure_ascii=False))
        self.assertEqual(code, 0, text)
        return json.loads(text)

    def test_a_field_of_the_wrong_kind_is_refused_in_words_never_a_traceback(self):
        wrong = (0, 1.5, True, "x", [], {}, ["a"], {"a": 1}, None)
        for action, (payload, _, _) in CASES.items():
            if action in sprint.RAW_ACTIONS:
                continue
            fields = [(None, k) for k in payload] + [("session", k) for k in (payload.get("session") or {})]
            for where, name in fields:
                for value in wrong:
                    bad = json.loads(json.dumps(payload))
                    (bad[where] if where else bad)[name] = value
                    with self.subTest(action=action, field=name, value=value):
                        self.tearDown()
                        self.setUp()
                        out = self.answer(action, bad)
                        self.assertNotRegex(out.get("error") or "", UNHANDLED)

    def test_a_payload_that_is_not_an_object_is_refused(self):
        for raw in ("[]", "3", '"x"', "null"):
            code, text = self.run_main("panel.state", raw)
            self.assertEqual((code, json.loads(text).get("error")), (0, "輸入要是 JSON 物件"), raw)

    def test_the_kinds_the_reviewer_found_crashing(self):
        self.assertEqual(self.answer("sprint.new", {"label": 7})["error"], "label 要是文字")
        self.assertEqual(self.answer("ticket.add", {"key": ["PROJ-2"]})["error"], "key 要是文字")
        self.assertEqual(self.answer("tick", {"now": "soon", "sessions": []})["error"], "now 要是數字")
        self.assertEqual(self.answer("session.shares", {"session": SESSION, "shares": {"PROJ-1": "x"}})["error"], "分攤要是數字")

    def test_ticket_update_never_makes_a_ticket_and_refuses_what_it_does_not_store(self):
        self.assertIn("不認得 PROJ-404", self.answer("ticket.update", {"key": "PROJ-404", "starred": True})["error"])
        self.assertNotIn("PROJ-404", self.files()["tickets.json"])
        self.assertIn("不收 estimate", self.answer("ticket.update", {"key": "PROJ-1", "estimate": 3})["error"])
        self.assertNotIn("error", self.answer("ticket.update", {"key": "PROJ-1", "notes": "備註 📝", "session": SESSION}))

    def test_a_key_goes_into_a_jira_write_only_if_it_is_a_known_ticket_in_exact_form(self):
        import common
        made, real = [], common.Jira
        common.Jira = lambda *a: made.append(a)
        store = Store(self.data)
        store.config["actualPointsField"] = "customfield_2"
        store.add_manual("PROJ-1", 1794300000, 60)
        store.save()
        try:
            for key in ("PROJ-404", "proj-1", "PROJ-1/../PROJ-2", "../PROJ-1", "PROJ-1?x=1", "PROJ-1#", "PROJ-1 ", " PROJ-1", "PROJ-1\n", ""):
                for action in ("points.push", "ticket.transition"):
                    with self.subTest(action=action, key=key):
                        self.assertRegex(self.answer(action, {"key": key, "id": "31"})["error"], "單號格式不對|不認得")
        finally:
            common.Jira = real
        self.assertEqual(made, [])

    def test_reading_actions_take_what_a_person_types(self):
        # Lower case is fine where a ticket is being brought in: only the format is checked there.
        self.assertIn(NO_JIRA, self.answer("ticket.add", {"key": "proj-2"})["error"])
        self.assertIn("不是 PROJ 的單號", self.answer("ticket.add", {"key": "../x"})["error"])

    def test_settings_take_only_custom_field_ids_for_jira_fields(self):
        before = self.files()
        for value in ("summary", "", "   ", "CUSTOMFIELD_1", "customfield_", "customfield_1 2", "customfield_1/x"):
            with self.subTest(pointsField=value):
                self.assertIn("customfield_<數字>", self.answer("config.set", {"pointsField": value})["error"])
        for value in ("summary", "CUSTOMFIELD_1"):
            with self.subTest(actualPointsField=value):
                self.assertIn("customfield_<數字>", self.answer("config.set", {"actualPointsField": value})["error"])
        self.assertEqual(self.files(), before)
        config = self.answer("config.set", {"pointsField": " customfield_10016 ", "actualPointsField": ""})["config"]
        self.assertEqual((config["pointsField"], config["actualPointsField"]), ("customfield_10016", ""))
        self.assertEqual(self.answer("config.set", {"actualPointsField": " customfield_77 "})["config"]["actualPointsField"], "customfield_77")

    def test_a_field_name_already_stored_wrong_never_reaches_jira(self):
        import common
        made, real = [], common.Jira
        common.Jira = lambda *a: made.append(a)
        store = Store(self.data)
        store.config.update(actualPointsField="summary", pointsField="assignee")
        store.add_manual("PROJ-1", 1794300000, 60)
        store.save()
        try:
            self.assertIn("實際點數欄位", self.answer("points.push", {"key": "PROJ-1"})["error"])
            self.assertIn("估點欄位", self.answer("sprint.sync", {})["error"])
            self.assertIn("估點欄位", self.answer("ticket.add", {"key": "PROJ-2"})["error"])
        finally:
            common.Jira = real
        self.assertEqual(made, [])


if __name__ == "__main__":
    unittest.main()
