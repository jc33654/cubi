"""Sprint actions: create, edit, select, pull the tickets from Jira."""
import common
import review
from common import apply_issue, fetch_tickets, jira_field, target_sprint
from jira import TICKET_FIELDS, parse_issue
from panel import panel_state


def sprint_new(store, p):
    label = (p.get("label") or "").strip()
    if not label:
        raise ValueError("要給 sprint 的標籤（例如 Sprint7）")
    store.new_sprint(label, p.get("name", ""), p.get("start", ""), p.get("end", ""), p.get("goal", ""))
    return panel_state(store, p)


def sprint_update(store, p):
    s = target_sprint(store, p)
    for k in ("name", "start", "end", "goal"):
        if k in p:
            s[k] = p[k]
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
    found = []
    for issue in common.jira(store).search(jql, TICKET_FIELDS + [field]):
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
    return panel_state(store, p)


def sprint_at(store, ts):
    """The sprint whose dates hold `ts`, if any."""
    for s in store.sprints["sprints"].values():
        since, until = review.sprint_range(s)
        if since is not None and until is not None and since <= ts < until:
            return s
    return None
