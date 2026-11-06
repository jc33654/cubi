"""Helpers every sprint command shares: Jira access, the payload's session, the target sprint."""
from jira import TICKET_FIELDS, Jira, JiraError, parse_issue
import review


def jira(store):
    return Jira(store.config["site"], store.config["netrc"])


def fetch_tickets(store, keys):
    """Refresh these tickets from Jira; local fields (notes, doneAt, starred) are kept. A key Jira
    does not know is remembered as notFound so it is not asked again every minute."""
    if not keys:
        return
    field = store.config["pointsField"]
    j = jira(store)
    try:
        issues = j.search(f"key in ({','.join(keys)})", TICKET_FIELDS + [field])
    except JiraError as e:
        if e.code != 400:
            raise
        # One unknown key fails the whole search: ask one by one.
        issues = []
        for key in keys:
            try:
                issues.append(j.issue(key, TICKET_FIELDS + [field]))
            except JiraError as single:
                if single.code not in (400, 404):
                    raise
                store.ticket(key)["notFound"] = True
    seen = set()
    for issue in issues:
        apply_issue(store, parse_issue(issue, field))
        seen.add(issue["key"])
    for key in keys:
        if key not in seen and not store.tickets.get(key, {}).get("summary"):
            store.ticket(key)["notFound"] = True


def apply_issue(store, parsed):
    t = store.ticket(parsed["key"])
    was_done = t.get("done")
    t.update({k: parsed[k] for k in ("summary", "status", "statusCategory", "done", "resolutionDate")})
    t.pop("notFound", None)
    if parsed["estimate"] is not None:
        t["estimate"] = parsed["estimate"]
    if parsed["done"] and not was_done and not t.get("doneAt"):
        t["doneAt"] = parsed["resolutionDate"] or date.today().isoformat()
    if not parsed["done"]:
        t["doneAt"] = None


def session_of(p):
    return p.get("session") or p


def target_sprint(store, p):
    """The sprint the payload names, else the current one; a name that does not exist is an error,
    never silently the current sprint."""
    if p.get("label"):
        s = store.sprint(p["label"])
        if not s:
            raise ValueError(f"沒有 sprint「{p['label']}」")
        return s
    s = store.current_sprint()
    if not s:
        raise ValueError("先建一個 sprint")
    return s


pts = review.pts


def rows_for(store, sprint):
    since, until = review.sprint_range(sprint)
    return review.ticket_rows(sprint, store.tickets, store.hours_by_key(since, until), store.hours_per_point(), store.hours_by_key())


# ---------- session hook ----------
