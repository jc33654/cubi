"""Batch 33: tickets of the sprint Jira now has assigned to someone else (or to nobody) are
marked after a sync; the ones not yet answered are asked about, and taken out only on a yes."""
import tempfile
import time
import unittest

import common
import sprint
from jira import TICKET_FIELDS, JiraError, owner, parse_issue
from store import Store

ME = {"accountId": "acc-me", "displayName": "Me"}
ALICE = {"accountId": "acc-alice", "displayName": "Alice"}
NOBODY = object()


def issue(key, assignee=None, done=False):
    fields = {"summary": f"單 {key}", "status": {"name": "完成" if done else "進行中", "statusCategory": {"key": "done" if done else "indeterminate"}}}
    if assignee is NOBODY:
        fields["assignee"] = None
    elif assignee is not None:
        fields["assignee"] = assignee
    return {"key": key, "fields": fields}


class FakeJira:
    """The sprint's query returns `found`; every other key comes back from the key search."""

    def __init__(self, issues, me=ME):
        self.issues, self.me = issues, me

    def search(self, jql, fields):
        if jql.startswith("key in"):
            return [i for k, i in self.issues.items() if k in jql]
        return list(self.issues.values())

    def issue(self, key, fields):
        return self.issues[key]

    def myself(self):
        if isinstance(self.me, Exception):
            raise self.me
        return {"id": self.me["accountId"], "name": self.me["displayName"]}


class ReassignTests(unittest.TestCase):
    def setUp(self):
        self.dir = tempfile.TemporaryDirectory()
        self.store = Store(self.dir.name)
        self.store.config.update(projectKey="PROJ", site="jira.example", jql="labels = {label}", pointsField="customfield_10016")
        self.store.new_sprint("Sprint7", "", "2020-01-01", "2099-12-31")
        self.real = common.jira

    def tearDown(self):
        common.jira = self.real
        self.store.close()
        self.dir.cleanup()

    def sync(self, issues, me=ME):
        common.jira = lambda store: FakeJira(issues, me)
        return sprint.sprint_sync(self.store, {})

    def owners(self, state):
        return {t["key"]: t["owner"] for t in state["sprint"]["tickets"]}

    def asked(self, state):
        return [a["key"] for a in state["sprint"]["reassigned"]]

    def test_reading_the_assignee(self):
        self.assertEqual(owner({"assignee": ALICE}), {"id": "acc-alice", "name": "Alice"})
        self.assertEqual(owner({"assignee": None}), {"id": None})                  # Jira says: nobody
        self.assertIsNone(owner({}))                                               # not in the answer: not known
        self.assertIsNone(owner({"assignee": {"displayName": "沒有 id 的人"}}))   # no account id: not known
        self.assertIn("assignee", TICKET_FIELDS)
        self.assertEqual(parse_issue(issue("PROJ-1", ALICE), "customfield_10016")["owner"]["id"], "acc-alice")

    def test_someone_elses_open_ticket_is_marked_and_asked_about_mine_is_not(self):
        state = self.sync({"PROJ-1": issue("PROJ-1", ME), "PROJ-2": issue("PROJ-2", ALICE)})
        self.assertEqual(self.owners(state), {"PROJ-1": None, "PROJ-2": {"kind": "other", "name": "Alice"}})
        self.assertEqual(state["sprint"]["reassigned"], [{"key": "PROJ-2", "name": "Alice", "summary": "單 PROJ-2"}])
        self.assertTrue(state["sprint"]["ownerKnown"])
        self.assertNotIn("notices", state)
        self.assertEqual(self.store.sprints["me"], {"id": "acc-me", "name": "Me"})

    def test_compared_by_account_id_never_by_name(self):
        twin = {"accountId": "acc-other-me", "displayName": "Me"}
        state = self.sync({"PROJ-1": issue("PROJ-1", twin)})
        self.assertEqual(self.asked(state), ["PROJ-1"])

    def test_done_or_worked_on_this_sprint_is_only_marked(self):
        self.store.add_manual("PROJ-3", time.time() - 7200, 30)
        self.store.add_to_sprint("Sprint7", "PROJ-3")
        state = self.sync({"PROJ-2": issue("PROJ-2", ALICE, done=True), "PROJ-3": issue("PROJ-3", ALICE)})
        self.assertEqual(self.owners(state)["PROJ-2"]["kind"], "other")
        self.assertEqual(self.owners(state)["PROJ-3"]["kind"], "other")
        self.assertEqual(self.asked(state), [])

    def test_nobody_is_only_marked(self):
        state = self.sync({"PROJ-4": issue("PROJ-4", NOBODY)})
        self.assertEqual(self.owners(state)["PROJ-4"], {"kind": "none"})
        self.assertEqual(self.asked(state), [])

    def test_a_ticket_added_by_hand_is_only_marked(self):
        common.jira = lambda store: FakeJira({"PROJ-5": issue("PROJ-5", ALICE)})
        sprint.ticket_add(self.store, {"key": "PROJ-5"})
        self.assertEqual(self.store.current_sprint()["handAdded"], ["PROJ-5"])
        state = self.sync({"PROJ-5": issue("PROJ-5", ALICE)})
        self.assertEqual(self.owners(state)["PROJ-5"]["kind"], "other")
        self.assertEqual(self.asked(state), [])

    def test_adding_again_what_the_sync_brought_is_not_by_hand(self):
        self.sync({"PROJ-6": issue("PROJ-6", ME)})
        common.jira = lambda store: FakeJira({"PROJ-6": issue("PROJ-6", ME)})
        sprint.ticket_add(self.store, {"key": "PROJ-6"})
        self.assertNotIn("handAdded", self.store.current_sprint())

    def test_let_be_stays_and_is_not_asked_about_again_in_that_sprint(self):
        issues = {"PROJ-2": issue("PROJ-2", ALICE), "PROJ-7": issue("PROJ-7", ALICE)}
        self.sync(issues)
        state = sprint.ticket_keep(self.store, {"key": "PROJ-2"})
        self.assertEqual(self.asked(state), ["PROJ-7"])
        self.assertIn("PROJ-2", self.store.current_sprint()["keys"])
        self.assertEqual(self.asked(self.sync(issues)), ["PROJ-7"])
        self.assertEqual(self.owners(state)["PROJ-2"]["kind"], "other")     # still marked
        with self.assertRaises(ValueError):
            sprint.ticket_keep(self.store, {"key": "PROJ-99"})

    def test_when_who_i_am_is_not_known_nothing_is_marked_and_it_says_so(self):
        self.sync({"PROJ-2": issue("PROJ-2", ALICE)})
        state = self.sync({"PROJ-2": issue("PROJ-2", ALICE)}, me=JiraError("連不上 Jira"))
        self.assertEqual(self.owners(state), {"PROJ-2": None})
        self.assertEqual(self.asked(state), [])
        self.assertFalse(state["sprint"]["ownerKnown"])
        self.assertIn("這次沒有檢查哪些單已轉派", state["notices"][0])
        self.assertNotIn("me", self.store.sprints)

    def test_an_answer_without_the_assignee_field_is_not_known_and_drops_what_was_read_before(self):
        self.sync({"PROJ-2": issue("PROJ-2", ALICE)})
        state = self.sync({"PROJ-2": issue("PROJ-2")})          # the field hidden from this account
        self.assertEqual(self.owners(state), {"PROJ-2": None})
        self.assertEqual(self.asked(state), [])
        self.assertNotIn("owner", self.store.tickets["PROJ-2"])

    def test_an_old_assignee_string_from_an_earlier_version_is_not_read(self):
        self.store.add_to_sprint("Sprint7", "PROJ-8")
        self.store.ticket("PROJ-8")["assignee"] = "Alice Lin"
        self.store.sprints["me"] = {"id": "acc-me", "name": "Me"}
        state = sprint.panel_state(self.store, {})
        self.assertEqual(self.owners(state), {"PROJ-8": None})

    def test_tickets_now_someone_elses_are_taken_out_all_or_none(self):
        issues = {k: issue(k, ALICE) for k in ("PROJ-1", "PROJ-2", "PROJ-3")}
        self.sync(issues)
        with self.assertRaises(ValueError):
            sprint.tickets_remove(self.store, {"keys": ["PROJ-1", "PROJ-99"]})
        self.assertEqual(self.store.current_sprint()["keys"], ["PROJ-1", "PROJ-2", "PROJ-3"])
        with self.assertRaises(ValueError):
            sprint.tickets_remove(self.store, {"keys": []})
        state = sprint.tickets_remove(self.store, {"keys": ["PROJ-1", "PROJ-2"]})
        self.assertEqual(self.store.current_sprint()["keys"], ["PROJ-3"])
        self.assertEqual(self.asked(state), ["PROJ-3"])
        self.assertIn("PROJ-1", self.store.tickets)                     # the ticket itself stays
        self.assertNotIn("notices", state)

    def test_taking_out_says_which_had_hours(self):
        self.store.add_manual("PROJ-1", time.time() - 7200, 90)
        self.sync({"PROJ-1": issue("PROJ-1", ALICE), "PROJ-2": issue("PROJ-2", ALICE)})
        self.store.add_to_sprint("Sprint7", "PROJ-1")
        state = sprint.tickets_remove(self.store, {"keys": ["PROJ-1", "PROJ-2"]})
        self.assertEqual(len(state["notices"]), 1)
        self.assertIn("PROJ-1 在這一期有 1h30m 工時", state["notices"][0])
        self.assertEqual(len(self.store.segments["manual"]), 1)                # the hours stay


if __name__ == "__main__":
    unittest.main()
