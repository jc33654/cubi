"""F9: tickets Jira no longer knows, taking a ticket out of the sprint, and Jira's "field cannot
be set" in words. Case numbers are the PRD's."""
import tempfile
import unittest
from datetime import datetime

import autopush
import common
import sprint
from jira import JiraError
from store import Store

REFUSED = ('PUT /rest/api/3/issue/PROJ-1 → HTTP 400 {"errorMessages":[],"errors":{"customfield_10016":"Field \'customfield_10016\' cannot be set. '
           'It is not on the appropriate screen, or unknown."}}')


def issue(key, summary="從 Jira 讀到的"):
    return {"key": key, "fields": {"summary": summary, "status": {"name": "進行中", "statusCategory": {"key": "indeterminate"}}}}


class FakeJira:
    """A search that, like Jira's, says nothing about keys it cannot find; `known` are the tickets
    the search returns, `slow` the ones only a direct GET finds, everything else is a 404."""

    def __init__(self, known=(), slow=(), broken=None, refuse=None):
        self.known, self.slow, self.broken, self.refuse, self.calls = set(known), set(slow), broken, refuse, []

    def search(self, jql, fields):
        self.calls.append("search")
        return [issue(k) for k in sorted(self.known) if k in jql]

    def issue(self, key, fields):
        self.calls.append(key)
        if self.broken:
            raise self.broken
        if key in self.known or key in self.slow:
            return issue(key)
        raise JiraError(f"GET /rest/api/3/issue/{key} → HTTP 404 議題不存在，或您沒有其查看權限。", 404)

    def set_field(self, key, field, value):
        self.calls.append(("set", key, field, value))
        if self.refuse:
            raise self.refuse

    def edit_fields(self, key):
        # Where the edit screen cannot be asked about, a refused estimate is the original error
        # (the comment path is test_estimate_comment's).
        raise JiraError("GET editmeta → 連不上 Jira")


class MissingTicketTests(unittest.TestCase):
    def setUp(self):
        self.dir = tempfile.TemporaryDirectory()
        self.store = Store(self.dir.name)
        self.store.config.update(projectKey="PROJ", site="jira.example", jql="labels = {label}", pointsField="customfield_10016")
        self.store.new_sprint("Sprint7", "", "2026-11-16", "2026-11-29")
        for i in (1, 2, 3):
            self.store.add_to_sprint("Sprint7", f"PROJ-{i}")
            self.store.ticket(f"PROJ-{i}").update(summary=f"本機的 {i}", status="待辦事項", estimate=float(i))
        self.real = common.jira

    def tearDown(self):
        common.jira = self.real
        self.store.close()
        self.dir.cleanup()

    def jira(self, **how):
        fake = FakeJira(**how)
        common.jira = lambda store: fake
        return fake

    def row(self, state, key):
        return next(t for t in state["sprint"]["tickets"] if t["key"] == key)

    # ---------- a ticket Jira no longer knows ----------

    def test_F9_1_a_ticket_read_before_and_since_deleted_is_marked_by_a_sync(self):
        fake = self.jira(known={"PROJ-1", "PROJ-3"})
        state = sprint.sprint_sync(self.store, {})
        gone = self.row(state, "PROJ-2")
        self.assertEqual((gone["notFound"], gone["summary"], gone["estimate"]), (True, "本機的 2", 2.0))    # marked; what was read stays to be looked at
        self.assertFalse(self.row(state, "PROJ-1")["notFound"])
        self.assertEqual(fake.calls, ["search", "search", "PROJ-2"])        # the label query, the batch, and the one it left out by itself
        # It is still in the sprint and in the numbers: taking it out is the user's call (no permission looks the same).
        self.assertEqual((len(state["sprint"]["tickets"]), state["sprint"]["capacity"]["planned"]), (3, 6.0))

    def test_F9_2_a_ticket_known_to_be_gone_is_not_asked_about_again_and_adding_it_back_asks(self):
        fake = self.jira(known={"PROJ-1", "PROJ-3"})
        sprint.sprint_sync(self.store, {})
        fake.calls.clear()
        sprint.sprint_sync(self.store, {})
        self.assertNotIn("PROJ-2", fake.calls)
        fake.known.add("PROJ-2")                                              # restored in Jira, or access given back
        state = sprint.ticket_add(self.store, {"key": "PROJ-2"})
        self.assertEqual((self.row(state, "PROJ-2")["notFound"], self.row(state, "PROJ-2")["summary"]), (False, "從 Jira 讀到的"))

    def test_F9_3_a_ticket_the_search_is_only_behind_on_is_refreshed_not_marked(self):
        self.jira(known={"PROJ-1", "PROJ-3"}, slow={"PROJ-2"})
        state = sprint.sprint_sync(self.store, {})
        self.assertEqual((self.row(state, "PROJ-2")["notFound"], self.row(state, "PROJ-2")["summary"]), (False, "從 Jira 讀到的"))

    def test_F9_4_jira_being_down_marks_nothing(self):
        for failure in (JiraError("連不上 Jira：timed out"), JiraError("HTTP 500", 500), JiraError("Jira 認證失敗（401/403）", 403)):
            self.jira(known={"PROJ-1", "PROJ-3"}, broken=failure)
            with self.assertRaises(JiraError):
                sprint.sprint_sync(self.store, {})
            self.assertNotIn("notFound", self.store.tickets["PROJ-2"])

    def test_F9_5_only_so_many_are_asked_for_one_by_one_in_a_call(self):
        for i in range(4, 34):
            self.store.add_to_sprint("Sprint7", f"PROJ-{i}")
            self.store.ticket(f"PROJ-{i}").update(summary="曾經讀到過")
        fake = self.jira()                                                    # nothing exists any more
        sprint.sprint_sync(self.store, {})
        asked = [c for c in fake.calls if c != "search"]
        self.assertEqual(len(asked), common.CONFIRM_PANEL)
        self.assertEqual(sum(1 for t in self.store.tickets.values() if t.get("notFound")), 20)
        sprint.sprint_sync(self.store, {})                                    # the rest, next time
        self.assertEqual(sum(1 for t in self.store.tickets.values() if t.get("notFound")), 33)
        # From the session card (a hook, 20 seconds in all): three at a time.
        fake.calls.clear()
        for t in self.store.tickets.values():
            t.pop("notFound", None)
        session = {"id": "s1", "name": " ".join(f"PROJ-{i}" for i in range(1, 9)), "cwd": None, "segments": []}
        sprint.session_info(self.store, session, sync=True)
        self.assertEqual(len([c for c in fake.calls if c != "search"]), common.CONFIRM_HOOK)
        self.assertEqual((common.CONFIRM_PANEL, common.CONFIRM_HOOK), (20, 3))

    def test_F9_6_a_ticket_found_gone_stops_waiting_to_have_its_hours_written(self):
        self.store.config.update(actualHoursField="customfield_20001", autoPushHours=True)
        self.store.tickets["PROJ-2"]["hoursPush"] = {"since": 1.0, "pending": True}
        self.store.tickets["PROJ-3"]["hoursPush"] = {"since": 2.0, "pending": False, "error": "HTTP 404", "failedAt": 3.0}
        self.jira(known={"PROJ-1"})
        state = sprint.sprint_sync(self.store, {})
        self.assertEqual((state["hoursPush"]["pending"], state["hoursPush"]["stopped"], state["hoursPush"]["error"]), ([], [], None))
        self.assertEqual(autopush.waiting(self.store), [])

    # ---------- taking a ticket out of the sprint ----------

    def test_F9_7_removing_takes_it_out_of_this_sprint_and_nothing_else(self):
        self.store.new_sprint("Sprint8", "", "2026-11-30", "2026-12-13")
        self.store.add_to_sprint("Sprint8", "PROJ-2")
        self.store.sprints["current"] = "Sprint7"
        self.store.bind("s1", "PROJ-2")
        self.store.tickets["PROJ-2"].update(notes="備註", starred=True)
        state = sprint.ticket_remove(self.store, {"key": "PROJ-2"})
        self.assertEqual([t["key"] for t in state["sprint"]["tickets"]], ["PROJ-1", "PROJ-3"])
        self.assertNotIn("notices", state)                                    # no hours on it: nothing to say
        self.assertEqual(self.store.sprint("Sprint8")["keys"], ["PROJ-2"])    # other sprints keep it
        self.assertEqual((self.store.tickets["PROJ-2"]["notes"], self.store.tickets["PROJ-2"]["starred"], self.store.bindings["s1"]["keys"]), ("備註", True, ["PROJ-2"]))
        # …and from a sprint that is not the current one, by its label.
        sprint.ticket_remove(self.store, {"key": "PROJ-2", "label": "Sprint8"})
        self.assertEqual(self.store.sprint("Sprint8")["keys"], [])

    def test_F9_8_hours_on_it_stay_and_are_said_and_come_back_with_it(self):
        self.store.add_manual("PROJ-2", datetime.fromisoformat("2026-11-18T10:00").timestamp(), 90, note="會議")
        before = sprint.panel_state(self.store, {})["sprint"]["metrics"]["seconds"]
        state = sprint.ticket_remove(self.store, {"key": "PROJ-2"})
        self.assertEqual(state["notices"], ["PROJ-2 在這一期有 1h30m 工時，移出後不算進這一期（紀錄還在，加回來就恢復）"])
        self.assertEqual((before, state["sprint"]["metrics"]["seconds"], len(self.store.segments["manual"])), (5400, 0, 1))
        self.jira(known={"PROJ-2"})
        state = sprint.ticket_add(self.store, {"key": "PROJ-2"})
        self.assertEqual(state["sprint"]["metrics"]["seconds"], 5400)

    def test_F9_9_only_a_ticket_of_that_sprint_can_be_removed_and_jira_is_not_asked(self):
        fake = self.jira()
        self.store.ticket("PROJ-99")
        for key in ("PROJ-99", "PROJ-404", "proj-1", "PROJ-1/../x", "PROJ-1 ", "", 7, ["PROJ-1"]):
            with self.subTest(key=key):
                with self.assertRaisesRegex(ValueError, "Sprint7 裡沒有這張單"):
                    sprint.ticket_remove(self.store, {"key": key})
        with self.assertRaisesRegex(ValueError, "沒有 sprint「Nope」"):
            sprint.ticket_remove(self.store, {"key": "PROJ-1", "label": "Nope"})
        self.assertEqual((self.store.sprint("Sprint7")["keys"], fake.calls), (["PROJ-1", "PROJ-2", "PROJ-3"], []))
        # A ticket Jira no longer knows can be taken out like any other.
        self.store.tickets["PROJ-2"]["notFound"] = True
        self.assertEqual(len(sprint.ticket_remove(self.store, {"key": "PROJ-2"})["sprint"]["tickets"]), 2)

    # ---------- "cannot be set", in words ----------

    def test_F9_11_a_field_the_tickets_screen_lacks_is_said_in_words_for_every_write(self):
        self.store.config.update(actualPointsField="customfield_10016", actualHoursField="customfield_10016")
        self.store.add_manual("PROJ-1", datetime.fromisoformat("2026-11-18T10:00").timestamp(), 60)
        self.store.save()
        self.store = Store(self.dir.name)
        self.jira(known={"PROJ-1"}, refuse=JiraError(REFUSED, 400))
        for what, call in (("估點", lambda: sprint.estimate_set(self.store, {"key": "PROJ-1", "value": "3"})),
                           ("實際點數", lambda: sprint.points_push(self.store, {"key": "PROJ-1"})),
                           ("實際時數", lambda: sprint.hours_push(self.store, {"key": "PROJ-1"}))):
            with self.subTest(what=what):
                with self.assertRaises(JiraError) as caught:
                    call()
                text = str(caught.exception)
                self.assertTrue(text.startswith(f"這張單在 Jira 上不能寫{what}：它的專案或單的類型沒有這個欄位（customfield_10016），或欄位不在編輯畫面上。原始錯誤：PUT "), text)
                self.assertIn("cannot be set", text)                          # the original is still there to be searched for
                self.assertEqual(caught.exception.code, 400)
        self.assertEqual(self.store.ticket("PROJ-1")["estimate"], 1.0)        # and nothing was stored

    def test_F9_11_any_other_error_is_left_as_jira_said_it(self):
        for original in (JiraError("HTTP 400 {\"errors\":{\"customfield_10016\":\"Number value expected\"}}", 400),
                         JiraError("HTTP 400 Field 'customfield_99' cannot be set.", 400),          # another field
                         JiraError("Field 'customfield_10016' cannot be set.", 403),
                         JiraError("連不上 Jira：timed out")):
            self.assertIs(common.field_refused(original, "customfield_10016", "估點"), original)
        # The one tick writes on its own says it the same way, for the panel's card.
        self.assertIn("不能寫實際時數", str(common.field_refused(JiraError(REFUSED, 400), "customfield_10016", "實際時數")))


if __name__ == "__main__":
    unittest.main()
