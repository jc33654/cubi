"""A ticket with no estimate field: the estimate goes into a 【估點】 comment only after the user
saw it and pressed the button; Cubi edits its own comment and no other; the AI's reason never goes in."""
import tempfile
import time
import unittest

import common
import sprint
from estimate_comment import comment_doc, comment_text
from jira import JiraError, adf_text
from store import Store

FIELD = "customfield_10016"


class FakeJira:
    """`fields` are on the ticket's edit screen; a field that is not is refused the way a Jira in
    Chinese says it (no English words to match on)."""

    def __init__(self, fields=(), editmeta=None, refuse=None):
        self.fields, self.editmeta, self.refuse = set(fields), editmeta, refuse
        self.comments, self.calls, self.next_id = {}, [], 100
        self.during, self.fail_once = None, None   # run while a comment is being written; fail the next write

    def writing(self):
        if self.during:
            during, self.during = self.during, None
            during()
        if self.fail_once:
            error, self.fail_once = self.fail_once, None
            raise error

    def set_field(self, key, field, value):
        self.calls.append(("set", key, value))
        if self.refuse:
            raise self.refuse
        if field not in self.fields:
            raise JiraError(f"PUT /rest/api/3/issue/{key} → HTTP 400 {{\"errors\":{{\"{field}\":\"無法設定欄位，它不在適當的畫面上。\"}}}}", 400)

    def issue(self, key, fields):
        return {"key": key, "fields": {"summary": "甲", "status": {"name": "進行中", "statusCategory": {"key": "indeterminate"}}, fields[-1]: 3}}

    def edit_fields(self, key):
        self.calls.append(("editmeta", key))
        if self.editmeta:
            raise self.editmeta
        return self.fields | {"summary", "description"}

    def comment(self, key, cid):
        self.calls.append(("get", key, cid))
        if cid not in self.comments:
            raise JiraError(f"GET comment {cid} → HTTP 404", 404)
        return {"id": cid, "body": self.comments[cid]}

    def add_comment(self, key, doc):
        self.writing()
        self.next_id += 1
        cid = str(self.next_id)
        self.comments[cid] = doc
        self.calls.append(("add", key, doc))
        return {"id": cid}

    def edit_comment(self, key, cid, doc):
        self.writing()
        self.calls.append(("edit", key, cid, doc))
        if cid not in self.comments:
            raise JiraError(f"PUT comment {cid} → HTTP 404", 404)
        self.comments[cid] = doc
        return {"id": cid}

    def writes(self):
        return [c for c in self.calls if c[0] in ("add", "edit")]


class EstimateCommentTests(unittest.TestCase):
    def setUp(self):
        self.dir = tempfile.TemporaryDirectory()
        self.store = Store(self.dir.name)
        self.store.config.update(projectKey="PROJ", site="jira.example", pointsField=FIELD)
        self.store.new_sprint("Sprint7", "", "2026-11-16", "2026-11-29")
        self.store.add_to_sprint("Sprint7", "PROJ-1")
        self.store.ticket("PROJ-1").update(summary="甲", estimate=None)
        self.reopen()
        self.real = common.jira
        self.fake = FakeJira()
        common.jira = lambda store: self.fake

    def tearDown(self):
        common.jira = self.real
        self.store.close()
        self.dir.cleanup()

    def reopen(self):
        self.store.save()
        self.store.close()
        self.store = Store(self.dir.name)

    def act(self, name, **p):
        state = sprint.ACTIONS[name](self.store, {"key": "PROJ-1", **p})
        self.reopen()
        return state

    def row(self, state):
        return next(t for t in state["sprint"]["tickets"] if t["key"] == "PROJ-1")

    def test_the_words_and_their_bold_part(self):
        self.assertEqual(comment_text(0.3), "【估點】本單 0.3 點（1 點＝1 人天）")
        para = comment_doc(3.0)["content"][0]["content"]
        self.assertEqual([(n["text"], n.get("marks")) for n in para], [("【估點】本單 3 點（1 點＝1 人天）", [{"type": "strong"}])])
        self.assertEqual(adf_text(comment_doc(1.5)), comment_text(1.5))      # what Cubi wrote reads back the same

    def test_no_field_on_the_edit_screen_asks_first_and_writes_nothing(self):
        state = self.act("estimate.set", value="0.3")
        ask = self.row(state)["commentAsk"]
        self.assertEqual(ask, {"edit": None, "old": None, "lost": False, "changed": False, "value": 0.3,
                               "text": "【估點】本單 0.3 點（1 點＝1 人天）"})
        self.assertEqual(self.fake.writes(), [])
        self.assertIsNone(self.store.tickets["PROJ-1"]["estimate"])

    def test_any_other_answer_is_the_original_error_and_no_question(self):
        for fake, error in ((FakeJira(fields={FIELD}, refuse=JiraError("HTTP 400 需要數字", 400)), "需要數字"),   # the field is there
                            (FakeJira(editmeta=JiraError("連不上 Jira：timed out")), "無法設定欄位"),          # cannot tell
                            (FakeJira(refuse=JiraError("連不上 Jira：timed out")), "timed out"),
                            (FakeJira(refuse=JiraError("Jira 認證失敗（401/403）", 403)), "認證失敗")):
            self.fake = fake
            with self.subTest(error=error):
                with self.assertRaisesRegex(JiraError, error):
                    self.act("estimate.set", value="2")
                self.assertNotIn("commentAsk", self.store.tickets["PROJ-1"])
                self.assertEqual(fake.writes(), [])
        self.assertNotIn(("editmeta", "PROJ-1"), self.fake.calls)               # an error that is not a 400 never asks
        self.fake = FakeJira()
        with self.assertRaises(JiraError):                                        # clearing has no comment to write
            self.act("estimate.set", value="")
        self.assertEqual(self.fake.calls, [("set", "PROJ-1", None)])

    def test_pressing_the_button_writes_the_number_only_never_the_ai_reason(self):
        self.store.ticket("PROJ-1")["suggestion"] = {"points": 3, "confidence": "中", "reason": "改 login 與 token 兩處，機密 abc", "at": 1}
        self.reopen()
        self.act("estimate.set", value="3")
        state = self.act("estimate.comment", how="jira", value="99")             # a number sent with the click is not used
        [(_, key, doc)] = self.fake.writes()
        self.assertEqual((key, doc), ("PROJ-1", comment_doc(3.0)))
        self.assertNotIn("login", str(doc))
        t = self.store.tickets["PROJ-1"]
        self.assertEqual((t["estimate"], t["estimateVia"], t["estimateComment"]), (3.0, "comment", {"id": "101", "text": comment_text(3.0)}))
        self.assertNotIn("commentAsk", t)
        self.assertNotIn("suggestion", t)
        self.assertEqual((self.row(state)["commentAsk"], self.row(state)["estimateVia"]), (None, "comment"))

    def test_a_second_estimate_edits_cubis_own_comment_and_shows_what_it_says_now(self):
        self.act("estimate.set", value="1")
        self.act("estimate.comment", how="jira")
        self.fake.comments["101"] = {"type": "doc", "version": 1, "content": [{"type": "paragraph", "content": [{"type": "text", "text": "她手改過的字"}]}]}
        ask = self.row(self.act("estimate.set", value="2"))["commentAsk"]
        self.assertEqual((ask["edit"], ask["old"], ask["changed"], ask["lost"]), ("101", "她手改過的字", True, False))
        self.act("estimate.comment", how="jira")
        self.assertEqual(self.fake.writes()[-1], ("edit", "PROJ-1", "101", comment_doc(2.0)))
        self.assertEqual(len([w for w in self.fake.writes() if w[0] == "add"]), 1)
        self.assertEqual(self.store.tickets["PROJ-1"]["estimateComment"]["id"], "101")
        ask = self.row(self.act("estimate.set", value="2.5"))["commentAsk"]       # untouched since: not "changed"
        self.assertEqual((ask["old"], ask["changed"]), (comment_text(2.0), False))

    def test_a_comment_in_the_first_wording_is_not_taken_for_one_a_person_changed(self):
        # Batch 18 wrote the number and then a sentence; Cubi kept that whole text. Unchanged since,
        # it is Cubi's own, and the next estimate turns it into the number alone.
        first = "【估點】本單 1 點（1 點＝1 人天）。此單類型沒有估點欄位，所以用留言記錄，供 sprint 統計用。"
        self.fake.comments["90"] = {"type": "doc", "version": 1, "content": [{"type": "paragraph", "content": [
            {"type": "text", "text": "【估點】本單 1 點（1 點＝1 人天）", "marks": [{"type": "strong"}]},
            {"type": "text", "text": "。此單類型沒有估點欄位，所以用留言記錄，供 sprint 統計用。"}]}]}
        self.store.ticket("PROJ-1").update(estimate=1.0, estimateVia="comment", estimateComment={"id": "90", "text": first})
        self.reopen()
        ask = self.row(self.act("estimate.set", value="2"))["commentAsk"]
        self.assertEqual((ask["edit"], ask["old"], ask["changed"], ask["text"]), ("90", first, False, "【估點】本單 2 點（1 點＝1 人天）"))
        self.act("estimate.comment", how="jira")
        self.assertEqual(self.fake.writes(), [("edit", "PROJ-1", "90", comment_doc(2.0))])
        self.assertEqual(self.store.tickets["PROJ-1"]["estimateComment"], {"id": "90", "text": "【估點】本單 2 點（1 點＝1 人天）"})

    def test_a_deleted_comment_is_said_on_the_row_and_a_new_one_needs_another_press(self):
        self.act("estimate.set", value="1")
        self.act("estimate.comment", how="jira")
        del self.fake.comments["101"]                                             # gone before the row was shown
        ask = self.row(self.act("estimate.set", value="2"))["commentAsk"]
        self.assertEqual((ask["edit"], ask["lost"]), (None, True))
        self.act("estimate.comment", how="jira")
        self.assertEqual(self.fake.writes()[-1][0], "add")
        self.act("estimate.set", value="3")                                       # gone after the row was shown
        del self.fake.comments["102"]
        state = self.act("estimate.comment", how="jira")
        self.assertIn("找不到了", state["warnings"][-1])
        self.assertEqual((self.fake.writes()[-1][0], self.store.tickets["PROJ-1"]["estimate"]), ("edit", 2.0))
        ask = self.row(state)["commentAsk"]
        self.assertEqual((ask["edit"], ask["lost"], ask["value"]), (None, True, 3.0))
        self.act("estimate.comment", how="jira")
        self.assertEqual((self.fake.writes()[-1][0], self.store.tickets["PROJ-1"]["estimateComment"]["id"]), ("add", "103"))

    def test_local_only_and_cancel_never_reach_jira(self):
        self.act("estimate.set", value="0.3")
        calls = list(self.fake.calls)
        state = self.act("estimate.comment", how="local")
        t = self.store.tickets["PROJ-1"]
        self.assertEqual((t["estimate"], t["estimateVia"], "estimateComment" in t), (0.3, "local", False))
        self.assertEqual(self.row(state)["estimate"], 0.3)
        self.act("estimate.set", value="5")
        self.act("estimate.comment", how="cancel")
        self.assertEqual((self.store.tickets["PROJ-1"]["estimate"], "commentAsk" in self.store.tickets["PROJ-1"]), (0.3, False))
        self.assertEqual(self.fake.writes(), [])
        self.assertEqual(self.fake.calls[len(calls):], [("set", "PROJ-1", 5.0), ("editmeta", "PROJ-1")])
        with self.assertRaisesRegex(ValueError, "沒有在等確認的估點留言"):
            self.act("estimate.comment", how="jira")
        self.act("estimate.set", value="5")
        with self.assertRaisesRegex(ValueError, "jira、local、cancel"):
            self.act("estimate.comment", how="post")

    def other(self, name, **p):
        """Another action, in a process of its own, while this one has let the lock go for Jira."""
        other = Store(self.dir.name)
        try:
            sprint.ACTIONS[name](other, {"key": "PROJ-1", **p})
            other.save()
        finally:
            other.close()

    def test_a_second_press_while_the_comment_is_sent_is_told_to_wait(self):
        self.act("estimate.set", value="1")
        refused = []

        def during():
            for name, p in (("estimate.comment", {"how": "jira"}), ("estimate.set", {"value": "2"})):
                with self.assertRaisesRegex(ValueError, "正在送出，請稍候"):
                    self.other(name, **p)
                refused.append(name)
        self.fake.during = during
        self.act("estimate.comment", how="jira")
        self.assertEqual(refused, ["estimate.comment", "estimate.set"])
        self.assertEqual([w[0] for w in self.fake.writes()], ["add"])             # one comment, not two
        t = self.store.tickets["PROJ-1"]
        self.assertEqual((t["estimate"], t["estimateComment"]["id"], "commentAsk" in t), (1.0, "101", False))

    def test_cancelled_and_asked_again_while_sent_keeps_the_comment_and_what_the_user_has_now(self):
        self.act("estimate.set", value="1")

        def during():
            self.other("estimate.comment", how="cancel")
            self.other("estimate.set", value="2")
        self.fake.during = during
        state = self.act("estimate.comment", how="jira")
        self.assertIn("確認列有變動，本機估點沒有跟著改", state["warnings"][-1])
        t = self.store.tickets["PROJ-1"]
        self.assertEqual((t["estimate"], t["estimateComment"]), (None, {"id": "101", "text": comment_text(1.0)}))
        ask = t["commentAsk"]
        self.assertEqual((ask["value"], ask["edit"], ask["old"], "sending" in ask), (2.0, "101", comment_text(1.0), False))
        self.act("estimate.comment", how="jira")                                  # edits that comment, adds none
        self.assertEqual([w[0] for w in self.fake.writes()], ["add", "edit"])
        self.assertEqual(self.store.tickets["PROJ-1"]["estimate"], 2.0)

    def test_a_question_asked_before_cubis_comment_was_written_down_still_edits_it(self):
        # Where a press, a cancel and a new estimate cross: the question says "add", yet by the
        # time it is answered Cubi knows its comment.
        self.act("estimate.set", value="1")
        self.act("estimate.comment", how="jira")
        self.store.tickets["PROJ-1"]["commentAsk"] = {"edit": None, "old": None, "lost": False, "changed": False,
                                                      "value": 3.0, "text": comment_text(3.0), "at": 1}
        self.reopen()
        self.act("estimate.comment", how="jira")
        self.assertEqual([w[0] for w in self.fake.writes()], ["add", "edit"])
        self.assertEqual(self.fake.writes()[-1][2], "101")
        self.store.tickets["PROJ-1"]["commentAsk"] = {"edit": None, "old": None, "lost": True, "changed": False,
                                                      "value": 4.0, "text": comment_text(4.0), "at": 2}
        self.reopen()
        self.act("estimate.comment", how="jira")                                  # said "a new one": a new one
        self.assertEqual([w[0] for w in self.fake.writes()], ["add", "edit", "add"])

    def test_a_failed_write_or_a_mark_left_by_a_dead_run_does_not_block_the_next_press(self):
        self.act("estimate.set", value="1")
        self.fake.fail_once = JiraError("連不上 Jira：timed out")
        with self.assertRaisesRegex(JiraError, "timed out"):
            self.act("estimate.comment", how="jira")
        self.reopen()
        self.assertNotIn("sending", self.store.tickets["PROJ-1"]["commentAsk"])
        self.store.tickets["PROJ-1"]["commentAsk"]["sending"] = time.time() - 120
        self.reopen()
        self.act("estimate.comment", how="jira")
        self.assertEqual(([w[0] for w in self.fake.writes()], self.store.tickets["PROJ-1"]["estimate"]), (["add"], 1.0))

    def test_a_sync_keeps_the_estimate_jira_has_no_field_for_and_a_field_write_clears_the_marks(self):
        self.act("estimate.set", value="0.3")
        self.act("estimate.comment", how="local")
        common.apply_issue(self.store, {"key": "PROJ-1", "summary": "甲", "status": "進行中", "statusCategory": "indeterminate",
                                        "done": False, "resolutionDate": None, "estimate": None})
        self.assertEqual(self.store.tickets["PROJ-1"]["estimate"], 0.3)
        self.reopen()
        self.fake.fields.add(FIELD)                                               # the field was added to the screen later
        self.act("estimate.set", value="4")
        t = self.store.tickets["PROJ-1"]
        self.assertEqual((t["estimate"], "estimateVia" in t, "commentAsk" in t), (4.0, False, False))


if __name__ == "__main__":
    unittest.main()
