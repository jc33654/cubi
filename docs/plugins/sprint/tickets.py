"""Ticket actions: add to the sprint, local marks, Jira transitions, pushing the actual points."""
import math
import re
import unicodedata

import common
import review
from common import KEY_RE, apply_issue, fetch_tickets, field_refused, jira_field, known_key, target_sprint
from estimate_comment import ask_for, no_field_ask, refuse_while_sending
from jira import TICKET_FIELDS, JiraError, parse_issue
from panel import panel_state

ESTIMATE = re.compile(r"[0-9]+(\.[0-9]+)?")


def ticket_add(store, p):
    keys = store.extract_keys(p.get("key", ""))
    if not keys:
        raise ValueError(f"不是 {store.config['projectKey']} 的單號")
    s = store.current_sprint()
    if not s:
        raise ValueError("先建一個 sprint")
    for key in keys:
        store.add_to_sprint(s["label"], key)
    fetch_tickets(store, keys)
    return panel_state(store, p)


# What ticket.update takes; anything else (an estimate, say) is refused rather than dropped.
TICKET_FIELDS_LOCAL = {"key", "notes", "starred", "session"}


def ticket_update(store, p):
    extra = sorted(set(p) - TICKET_FIELDS_LOCAL)
    if extra:
        raise ValueError(f"ticket.update 只收備註與星號，不收 {'、'.join(extra)}")
    t = store.tickets[known_key(store, p["key"])]
    if "notes" in p:
        t["notes"] = p["notes"]
    if "starred" in p:
        t["starred"] = p["starred"] is True
    return panel_state(store, p)


def ticket_transition(store, p):
    key = known_key(store, p["key"])
    j = common.jira(store)
    if not p.get("id"):
        return {"transitions": j.transitions(key)}
    j.transition(key, p["id"])
    fetch_tickets(store, [key])
    return panel_state(store, p)


def points_push(store, p):
    field = jira_field(store, "actualPointsField", "實際點數欄位")
    if not field:
        raise ValueError("設定裡沒有「實際點數欄位」，先只存本機")
    key = known_key(store, p["key"])
    # The ticket's own field: every hour ever worked on it, not just this sprint's (as `remaining`).
    actual = review.actual_points(store.hours_by_key().get(key, {}).get("total", 0.0), store.hours_per_point())
    if actual is None:
        raise ValueError("這張單還沒有投入時數")
    try:
        common.jira(store).set_field(key, field, actual)
    except JiraError as e:
        raise field_refused(e, field, "實際點數")
    return panel_state(store, p)


def parse_estimate(value):
    """What the panel's estimate field holds, as points: a number above zero, or None for an empty
    field (not estimated). Full-width digits count; a comma, a space inside, 1e3 or a zero do not
    (zero points already reads as "not estimated" everywhere: it may not be a second way to say it)."""
    wrong = ValueError("估點要是大於 0 的數字（例如 0.5、3）；清空代表未估點")
    if value is None:
        return None
    if isinstance(value, bool) or not isinstance(value, (int, float, str)):
        raise wrong
    if isinstance(value, str):
        text = unicodedata.normalize("NFKC", value).strip()
        if not text:
            return None
        if not ESTIMATE.fullmatch(text):
            raise wrong
        value = float(text)
    if not math.isfinite(value) or value <= 0:
        raise wrong
    return float(value)


def estimate_set(store, p):
    """Write the ticket's estimate to Jira (`value` empty: clear it), then keep what was written.
    Jira is the truth: nothing is stored unless the write went through. The lock is not held
    while Jira is asked, and afterwards only this ticket is touched."""
    key = known_key(store, p["key"])
    field = jira_field(store, "pointsField", "估點欄位", required=True)
    value = parse_estimate(p.get("value"))
    j = common.jira(store)
    refuse_while_sending(store.tickets.get(key, {}).get("commentAsk"))
    mine = store.tickets.get(key, {}).get("estimateComment")

    def write():
        try:
            j.set_field(key, field, value)
        except JiraError as e:
            if e.code != 400 or value is None:
                raise
            return None, None, no_field_ask(j, key, field, e, mine)
        try:
            return j.issue(key, TICKET_FIELDS + [field]), None, None
        except JiraError as e:   # written, but the read-back failed: the estimate still stands
            return None, str(e), None
    try:
        issue, trouble, ask = store.away(write)
    except JiraError as e:
        raise field_refused(e, field, "估點")
    if ask:
        # No estimate field on this ticket: nothing is written until the user says so on the row.
        ask_for(store, key, value, ask)
        return panel_state(store, p)
    store.ticket(key).pop("commentAsk", None)
    store.ticket(key).pop("estimateVia", None)
    if issue:
        apply_issue(store, parse_issue(issue, field))
    # The value just written, not what the read-back said: a cleared field comes back empty, and
    # an empty answer never clears the local estimate (common.apply_issue).
    store.ticket(key)["estimate"] = value
    # A person set the estimate: an AI suggestion for it has done its job, taken or not.
    store.ticket(key).pop("suggestion", None)
    state = panel_state(store, p)
    if trouble:
        state["warnings"] = state.get("warnings", []) + [f"估點已寫進 Jira，但回讀工單失敗：{trouble}"]
    return state


def worked_hours(store, key):
    """Every hour ever worked on the ticket (all sprints, sessions and manual stretches alike, the
    same total `remaining` counts from), to two decimals."""
    return round(store.hours_by_key().get(key, {}).get("total", 0.0) / 3600, 2)


def hours_push(store, p):
    """Set the ticket's actual-hours field in Jira to the hours worked on it. It replaces what is
    there (pressing twice gives the same number), someone else's figure included."""
    field = jira_field(store, "actualHoursField", "實際時數欄位")
    if not field:
        raise ValueError("設定裡沒有「實際時數欄位」")
    key = known_key(store, p["key"])
    hours = worked_hours(store, key)
    if hours <= 0:
        raise ValueError("這張單還沒有投入時數")
    j = common.jira(store)
    try:
        store.away(lambda: j.set_field(key, field, hours))
    except JiraError as e:
        raise field_refused(e, field, "實際時數")
    return panel_state(store, p)


def ticket_remove(store, p):
    """Take one ticket out of the sprint (`label`, else the current one). Only the sprint's list
    changes: the ticket, the hours booked on it and what sessions are bound to it all stay, and
    adding it back brings its numbers back. Jira is not asked; a ticket that still carries the
    sprint's label there returns with the next sync."""
    s = target_sprint(store, p)
    key = p["key"]
    if not isinstance(key, str) or not KEY_RE.fullmatch(key) or key not in s["keys"]:
        raise ValueError(f"{s['label']} 裡沒有這張單")
    since, until = review.sprint_range(s)
    worked = store.hours_by_key(since, until).get(key, {}).get("total", 0.0)
    s["keys"].remove(key)
    state = panel_state(store, p)
    if worked >= 60:
        state["notices"] = [f"{key} 在這一期有 {review.fmt_hours(worked)} 工時，移出後不算進這一期（紀錄還在，加回來就恢復）"]
    return state
