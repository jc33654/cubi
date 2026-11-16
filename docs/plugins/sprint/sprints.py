"""Sprint actions: create, edit, select, pull the tickets from Jira."""
import cadence
import common
import review
from common import apply_issue, fetch_tickets, jira_field, target_sprint
from jira import TICKET_FIELDS, JiraError, parse_issue
from panel import panel_state


def sprint_new(store, p):
    label = (p.get("label") or "").strip()
    if not label:
        raise ValueError("要給 sprint 的標籤（例如 Sprint7）")
    start, end = (p.get("start") or "").strip(), (p.get("end") or "").strip()
    cadence.check_dates(store.sprints["sprints"].values(), label, start, end)
    before, known = store.sprints.get("current"), label in store.sprints["sprints"]
    s = store.new_sprint(label, p.get("name") or "", start, end, p.get("goal") or "")
    first_day = review.parse_date(start)
    if before and not known and first_day and first_day > cadence.today():
        # The next sprint, made ahead of its first day (at Friday's planning): the panel stays on
        # the running one, and tick moves over when the new one's days begin.
        store.sprints["current"] = before
        s["waiting"] = True
    return panel_state(store, p)


def sprint_update(store, p):
    s = target_sprint(store, p)
    if "start" in p or "end" in p:
        start = (p["start"] if "start" in p else s.get("start")) or ""
        end = (p["end"] if "end" in p else s.get("end")) or ""
        cadence.check_dates(store.sprints["sprints"].values(), s["label"], start.strip(), end.strip())
    for k in ("name", "start", "end", "goal"):
        if k in p:
            s[k] = (p[k] or "").strip() if k in ("start", "end") else p[k]
    return panel_state(store, p)


def sprint_select(store, p):
    if p.get("label") not in store.sprints["sprints"]:
        raise ValueError("沒有這個 sprint")
    store.sprints["current"] = p["label"]
    return panel_state(store, p)


def sprint_sync(store, p):
    """Pull the sprint's tickets from Jira. `replace` makes the sprint exactly what the JQL
    returns (dropping tickets added by hand or by an earlier, wider query)."""
    s = target_sprint(store, p)
    projects = store.project_keys()
    jql = store.config["jql"].format(projects=", ".join(projects), project=projects[0] if projects else "", label=s["label"])
    field = jira_field(store, "pointsField", "估點欄位", required=True)
    found, j = [], common.jira(store)
    for issue in j.search(jql, TICKET_FIELDS + [field]):
        apply_issue(store, parse_issue(issue, field))
        found.append(issue["key"])
    if p.get("replace"):
        store.set_sprint_keys(s["label"], found)
    else:
        for key in found:
            store.add_to_sprint(s["label"], key)
    # Tickets the query does not return (added by hand) are refreshed too, so their status and its
    # colour never stay as they were first read; not the ones Jira already said it does not know.
    fetch_tickets(store, [k for k in s["keys"] if k not in found and not store.tickets.get(k, {}).get("notFound")])
    # Who "me" is, for telling the tickets now assigned to someone else. Not known: nothing is told
    # (never every ticket as someone else's), and the panel says so.
    try:
        store.sprints["me"] = j.myself()
    except JiraError:
        store.sprints.pop("me", None)
    state = panel_state(store, p)
    if "me" not in store.sprints:
        state["notices"] = ["讀不到你的 Jira 帳號（/myself），這次沒有檢查哪些單已轉派"]
    return state


def sprint_at(store, ts):
    """The sprint whose dates hold `ts`, if any (the same reading the hours are counted by)."""
    label = store.sprint_of({"start": ts})
    return store.sprint(label) if label else None
