import json
import os
import tempfile
import time
import unittest

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

    def actions(self, out):
        return [a["action"] for a in out["actions"]]

    def test_pause_stays_after_the_last_ticket_is_unbound(self):
        sprint.timer_start(self.store, self.session)
        out = sprint.session_unbind(self.store, {**self.session, "input": "PROJ-1"})
        self.store.bindings["s1"]["removed"] = ["PROJ-1"]
        out = sprint.session_info(self.store, self.session)
        self.assertIn("timer.stop", self.actions(out))
        self.assertTrue(any((r.get("label") if isinstance(r, dict) else r[0]) == "計時中" for r in out["rows"]))

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
