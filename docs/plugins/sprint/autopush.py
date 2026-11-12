"""Writing the hours worked on a ticket to Jira on its own (F7): actions that book or change
hours only note the ticket as waiting; tick writes a few of them each minute, without holding the
data lock while Jira is asked."""
import time

import common
from jira import Jira, JiraError
from tickets import worked_hours

REQUEST_TIMEOUT = 5      # seconds Jira gets per ticket
PER_TICK = 3             # tickets written in one tick at most
BUDGET = 10              # seconds after which no further ticket is started (worst case 15 s; hooks are killed at 20)
# Answers that will not get better by asking again: no permission, no such field, no such ticket.
FINAL = (400, 401, 403, 404)


def field(store):
    """The actual-hours field when writing on its own is switched on and set up, else ''."""
    if not store.config.get("autoPushHours"):
        return ""
    try:
        return common.jira_field(store, "actualHoursField", "實際時數欄位")
    except ValueError:
        return ""


def queue(store, keys, now=None):
    """Note these tickets as waiting to have their hours written. A ticket waits once however
    often it is noted; noting it again after a refusal lets it be tried again (there is new work
    on it). Nothing happens while the feature is off."""
    if not field(store):
        return
    for key in keys:
        if key in store.tickets:
            waiting = store.tickets[key].get("hoursPush") or {}
            store.tickets[key]["hoursPush"] = {"since": waiting.get("since") if waiting.get("pending") else (now or time.time()), "pending": True}


def keys_of(entry):
    """The tickets a manual stretch counts for."""
    return list(entry.get("shares") or ([entry["key"]] if entry.get("key") else []))


def waiting(store):
    return sorted((k for k, t in store.tickets.items() if (t.get("hoursPush") or {}).get("pending")),
                  key=lambda k: (store.tickets[k]["hoursPush"].get("since") or 0, k))


def status(store):
    """For the panel: which tickets still wait, and what went wrong last for those that failed."""
    marks = {k: t["hoursPush"] for k, t in store.tickets.items() if t.get("hoursPush")}
    failed = sorted(((m.get("failedAt") or 0, k, m) for k, m in marks.items() if m.get("error")), reverse=True)
    return {"on": bool(field(store)), "pending": waiting(store),
            "stopped": sorted(k for k, m in marks.items() if m.get("error") and not m.get("pending")),
            "error": f"{failed[0][1]}：{failed[0][2]['error']}" if failed else None}


def retry(store, now=None):
    """Every ticket that was given up on waits again."""
    for key, t in store.tickets.items():
        mark = t.get("hoursPush")
        if mark and not mark.get("pending"):
            t["hoursPush"] = {"since": now or time.time(), "pending": True}


def push_waiting(store):
    """Write the hours of up to PER_TICK waiting tickets. Called at the end of tick: what tick did
    is saved first and the lock given up, Jira is asked, then the files are read again and only
    the tickets' waiting marks are touched. A hook killed half-way leaves a written ticket
    waiting; it is written again next time with the same number."""
    target, keys = field(store), waiting(store)[:PER_TICK]
    if not target or not keys or common.dry_run():
        return
    todo = [(key, worked_hours(store, key)) for key in keys]
    j = Jira(store.config["site"], store.config["netrc"], timeout=REQUEST_TIMEOUT)

    def write():
        started, results = time.monotonic(), {}
        for key, hours in todo:
            if time.monotonic() - started > BUDGET:
                break
            try:
                j.set_field(key, target, hours)
                results[key] = None
            except JiraError as e:
                results[key] = e
            except Exception as e:  # noqa: BLE001 — an answer that is not JSON (a proxy's page, a login form)…
                # Whatever goes wrong with one ticket is that ticket's, and worth another try:
                # tick's own work (the stretches it recorded, the calendar it returns) must not
                # fail because of it, nor the other tickets of this round.
                results[key] = JiraError(f"{type(e).__name__}: {e}")
        return results
    results = store.away(write, save_first=True)
    for key, error in results.items():
        ticket = store.tickets.get(key)
        if ticket is None:
            continue
        if error is None:
            ticket.pop("hoursPush", None)
        else:
            mark = ticket.get("hoursPush") or {"since": time.time()}
            # A refusal stops the retries for this ticket (it is kept, with why, for the panel);
            # anything else — no connection, a timeout, Jira having a bad minute — is tried again.
            ticket["hoursPush"] = {**mark, "pending": error.code not in FINAL, "error": str(error), "failedAt": time.time()}
