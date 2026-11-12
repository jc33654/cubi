"""Ticket actions: add to the sprint, local marks, Jira transitions, pushing the actual points."""
import common
import review
from common import fetch_tickets, jira_field, known_key
from panel import panel_state


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
    common.jira(store).set_field(key, field, actual)
    return panel_state(store, p)
