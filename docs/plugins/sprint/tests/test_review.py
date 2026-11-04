import json
import tempfile
import unittest
from datetime import date

import review
from jira import parse_issue
from store import Store

ISSUE = json.loads("""
{"key": "PROJ-12", "fields": {"summary": "範例工單 甲", "labels": ["Sprint7"], "resolutiondate": "2026-11-05T10:00:00.000+0800",
  "status": {"name": "處理完畢", "statusCategory": {"key": "done"}}, "customfield_10016": 3.5,
  "assignee": {"displayName": "某人"}, "updated": "2026-11-05T10:00:00.000+0800"}}
""")


class ReviewTests(unittest.TestCase):
    def setUp(self):
        self.dir = tempfile.TemporaryDirectory()
        self.store = Store(self.dir.name)
        s = self.store.new_sprint("Sprint7", "Sprint 7", "2026-11-03", "2026-11-14", "退場")
        for key, est, actual, done, done_at in (("PROJ-1", 5, 3, False, None), ("PROJ-2", 2, 3, True, "2026-11-05"), ("PROJ-3", 1, None, False, None)):
            self.store.add_to_sprint("Sprint7", key)
            self.store.ticket(key).update({"summary": f"工單 {key}", "status": "處理完畢" if done else "進行中", "estimate": est, "actual": actual, "done": done, "doneAt": done_at})
        self.sprint = s

    def tearDown(self):
        self.dir.cleanup()

    def rows(self):
        hours = {"PROJ-1": {"total": 40_800.0, "session": 40_800.0, "manual": 0.0, "meeting": 0.0},
                 "PROJ-2": {"total": 21_900.0, "session": 18_300.0, "manual": 3600.0, "meeting": 3600.0}}
        return review.ticket_rows(self.sprint, self.store.tickets, hours)

    def test_parse_issue_reads_points_status_and_done(self):
        t = parse_issue(ISSUE, "customfield_10016")
        self.assertEqual((t["key"], t["summary"], t["status"], t["done"], t["estimate"], t["resolutionDate"]),
                         ("PROJ-12", "範例工單 甲", "處理完畢", True, 3.5, "2026-11-05"))
        self.assertIsNone(parse_issue({"key": "X-1", "fields": {}}, "customfield_10016")["estimate"])

    def test_metrics(self):
        m = review.metrics(self.rows())
        self.assertEqual((m["tickets"], m["done"], m["estimate"], m["actual"], m["donePoints"]), (3, 1, 8, 6, 2))
        self.assertEqual(m["ratio"], 0.75)
        self.assertEqual(m["seconds"], 62_700.0)
        self.assertEqual(m["meetingSeconds"], 3600.0)
        self.assertEqual(m["hoursPerPoint"], round(62_700 / 3600 / 6, 1))

    def test_burndown_ideal_line_and_actual_up_to_today(self):
        b = review.burndown(self.sprint, self.rows(), today=date(2026, 11, 6))
        self.assertEqual(len(b), 12)
        self.assertEqual((b[0]["date"], b[0]["ideal"], b[0]["actual"]), ("2026-11-03", 8, 8))
        self.assertEqual((b[2]["date"], b[2]["actual"]), ("2026-11-05", 6))   # PROJ-2 (2 pts) done that day
        self.assertEqual(b[3]["actual"], 6)
        self.assertIsNone(b[4]["actual"])                                      # tomorrow: not yet
        self.assertEqual(b[-1]["ideal"], 0)
        self.assertEqual(review.burndown({"label": "x"}, []), [])

    def test_markdown(self):
        self.sprint["review"] = {"wentWell": ["一次過"], "toImprove": ["估少了"], "suggestions": ["加 buffer"], "thanks": [{"who": "某人", "why": "幫忙查"}]}
        md = review.markdown(self.sprint, self.rows(), review.metrics(self.rows()))
        self.assertIn("# Sprint 7 回顧（2026-11-03 – 2026-11-14）", md)
        self.assertIn("目標：退場", md)
        self.assertIn("| PROJ-1 | 工單 PROJ-1 | 進行中 | 5 | 3 | 11h20m |", md)
        self.assertIn("| PROJ-3 | 工單 PROJ-3 | 進行中 | 1 | – | – |", md)
        self.assertIn("合計：估 8 點、實際 6 點、完成 1/3、投入 17h25m（其中會議 1h00m）、估/實 0.75", md)
        self.assertIn("## 想感謝的夥伴\n\n- 某人：幫忙查", md)

    def test_fmt_hours(self):
        self.assertEqual([review.fmt_hours(x) for x in (0, 59, 60, 3600, 40_800)], ["–", "–", "1m", "1h00m", "11h20m"])


if __name__ == "__main__":
    unittest.main()
