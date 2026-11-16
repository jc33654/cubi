"""Tickets of the sprint Jira now has assigned to someone else, or to nobody.

A sync reads each ticket's assignee and who the user is (/myself); they are compared by account
id, never by name. Without the user's id (the sync could not ask) nothing is told. A ticket is
only marked when it is done, has hours in the sprint, was added by hand or was let be (略過);
otherwise the panel asks whether to take it out of the sprint."""

HAND_ADDED, LET_BE = "handAdded", "reassignSkip"


def owner_tag(store, ticket):
    """{"kind": "other", "name"} or {"kind": "none"}; None when it is the user's, or not known."""
    me, owner = store.sprints.get("me"), ticket.get("owner")
    if not isinstance(me, dict) or not me.get("id") or not isinstance(owner, dict):
        return None
    if owner.get("id") is None:
        return {"kind": "none"}
    if owner["id"] == me["id"]:
        return None
    return {"kind": "other", "name": owner.get("name") or ""}


def annotate(store, sprint, rows):
    """Puts each row's `owner` tag on it; answers the tickets to ask about taking out."""
    quiet = set(sprint.get(HAND_ADDED, [])) | set(sprint.get(LET_BE, []))
    ask = []
    for row in rows:
        row["owner"] = tag = owner_tag(store, store.tickets.get(row["key"], {}))
        if tag and tag["kind"] == "other" and not row["done"] and not row["seconds"] and not row["notFound"] and row["key"] not in quiet:
            ask.append({"key": row["key"], "name": tag["name"], "summary": row["summary"]})
    return ask


def note(sprint, field, key):
    keys = sprint.setdefault(field, [])
    if key not in keys:
        keys.append(key)
