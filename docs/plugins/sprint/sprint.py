#!/usr/bin/env python3
"""cubi sprint plugin: one command per action, JSON in on stdin, JSON out on stdout.

    python3 sprint.py <action> < payload.json

Every action takes the same envelope. From cubi's session hook the payload is the session
itself ({id, name, cwd, …, segments}); from the panel it is whatever the page sends, with the
session (if the panel was opened from one) under "session".
"""
import json
import os
import sys
import time
import traceback
from datetime import date, datetime

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import review  # noqa: E402
from jira import TICKET_FIELDS, Jira, JiraError, parse_issue  # noqa: E402
from store import Store, empty_review  # noqa: E402

CONFIG_KEYS = ("site", "netrc", "projectKey", "jql", "pointsField", "actualPointsField", "reviewDir")


def jira(store):
    return Jira(store.config["site"], store.config["netrc"])


def fetch_tickets(store, keys):
    """Refresh these tickets from Jira; local fields (actual, notes, doneAt) are kept. A key Jira
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
    t.update({k: parsed[k] for k in ("summary", "status", "done", "resolutionDate")})
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


def current_range(store):
    s = store.current_sprint()
    return review.sprint_range(s) if s else (time.time() - 14 * 86400, None)


def pts(v):
    return "–" if v is None else (str(int(v)) if float(v).is_integer() else str(v))


# ---------- session hook ----------

def session_info(store, p, sync=False):
    rec = store.binding(p)
    shares = store.shares(rec)
    store.record_segments(p, shares)
    keys = store.bound_keys(rec)
    error = None
    missing = [k for k in keys if not store.tickets.get(k, {}).get("summary") and not store.tickets.get(k, {}).get("notFound")]
    if keys and (sync or missing):
        try:
            fetch_tickets(store, keys if sync else missing)
        except JiraError as e:
            error = str(e)
    since, until = current_range(store)
    hours = store.hours_by_key(since, until)
    today = store.hours_by_key(datetime.combine(date.today(), datetime.min.time()).timestamp(), None)
    rows = []
    for key in keys:
        t = store.tickets.get(key, {})
        rows.append({"label": key, "url": store.browse_url(key),
                     "value": " · ".join(x for x in [t.get("summary") or ("Jira 查不到這張單" if t.get("notFound") else "（還沒從 Jira 讀到）"), t.get("status"),
                                                      f"估 {pts(t.get('estimate'))} 實 {pts(t.get('actual'))}",
                                                      review.fmt_hours(hours.get(key, {}).get("total", 0))] if x)})
    if not keys:
        rows.append(["工單", "未綁定；用「開面板」加"])
    else:
        today_secs = sum(today.get(k, {}).get("session", 0) for k in keys)
        split = f"（{len(keys)} 張單依比例分）" if len(keys) > 1 else ""
        rows.append(["今日", review.fmt_hours(today_secs) + split])
    sprint = store.current_sprint()
    out = {"title": f"Sprint · {sprint['label']}" if sprint else "Sprint", "rows": rows,
           "actions": [{"label": "同步 Jira", "action": "session.sync"}] if keys else []}
    if error:
        out["error"] = error
    return out


def tick(store, p):
    for session in p.get("sessions", []):
        rec = store.binding(session)
        store.record_segments(session, store.shares(rec))
    return {"calendar": store.calendar_entries(p.get("now") or time.time())}


# ---------- panel ----------

def panel_state(store, p):
    sprint = store.current_sprint()
    session = p.get("session")
    binding = None
    if session:
        rec = store.binding(session)
        binding = {"id": session["id"], "name": session.get("name", ""), "cwd": session.get("cwd"),
                   "keys": store.bound_keys(rec), "auto": rec.get("auto", []), "shares": store.shares(rec)}
    state = {"config": {k: store.config.get(k) for k in CONFIG_KEYS}, "netrcFound": os.path.exists(os.path.expanduser(store.config["netrc"])),
             "sprints": [{"label": s["label"], "name": s.get("name"), "start": s.get("start"), "end": s.get("end")}
                         for s in sorted(store.sprints["sprints"].values(), key=lambda s: (s.get("start") or "", s["label"]))],
             "current": store.sprints.get("current"), "session": binding, "history": review.history(store),
             "today": date.today().isoformat(), "site": store.config["site"], "warnings": store.warnings}
    if sprint:
        since, until = review.sprint_range(sprint)
        rows = review.ticket_rows(sprint, store.tickets, store.hours_by_key(since, until))
        state["sprint"] = {**{k: sprint.get(k) for k in ("label", "name", "start", "end", "goal")}, "review": sprint.get("review") or empty_review(),
                           "tickets": rows, "metrics": review.metrics(rows), "burndown": review.burndown(sprint, rows),
                           "manual": [m for m in store.segments["manual"] if m["key"] in sprint["keys"]]}
    return state


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
    s = target_sprint(store, p)
    jql = store.config["jql"].format(project=store.config["projectKey"], label=s["label"])
    field = store.config["pointsField"]
    for issue in jira(store).search(jql, TICKET_FIELDS + [field]):
        apply_issue(store, parse_issue(issue, field))
        store.add_to_sprint(s["label"], issue["key"])
    fetch_tickets(store, [k for k in s["keys"] if not store.tickets.get(k, {}).get("summary")])
    return panel_state(store, p)


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


def ticket_update(store, p):
    t = store.ticket(p["key"])
    if "actual" in p:
        t["actual"] = float(p["actual"]) if p["actual"] not in (None, "") else None
    if "notes" in p:
        t["notes"] = p["notes"]
    return panel_state(store, p)


def ticket_transition(store, p):
    j = jira(store)
    if not p.get("id"):
        return {"transitions": j.transitions(p["key"])}
    j.transition(p["key"], p["id"])
    fetch_tickets(store, [p["key"]])
    return panel_state(store, p)


def points_push(store, p):
    field = store.config["actualPointsField"]
    if not field:
        raise ValueError("設定裡沒有「實際點數欄位」，先只存本機")
    t = store.ticket(p["key"])
    if t.get("actual") is None:
        raise ValueError("這張單還沒填實際點數")
    jira(store).set_field(p["key"], field, t["actual"])
    return panel_state(store, p)


def time_add(store, p):
    try:
        start = datetime.fromisoformat(p["start"]).timestamp()
    except (TypeError, ValueError):
        raise ValueError("開始時間格式不對")
    store.add_manual(p["key"], start, p.get("minutes"), p.get("kind", "開發"), p.get("note", ""), p.get("calendar", False))
    return panel_state(store, p)


def time_remove(store, p):
    store.remove_manual(p["id"])
    return panel_state(store, p)


def session_bind(store, p):
    s = session_of(p)
    for key in store.extract_keys(p.get("key", "")):
        store.bind(s["id"], key)
    return panel_state(store, p) if "session" in p else session_info(store, s)


def session_unbind(store, p):
    s = session_of(p)
    store.unbind(s["id"], p.get("key", ""))
    return panel_state(store, p) if "session" in p else session_info(store, s)


def session_shares(store, p):
    s = session_of(p)
    since = until = None
    if p.get("applyToSprint") and store.current_sprint():
        since, until = review.sprint_range(store.current_sprint())
        since = since or 0
    store.set_shares(s["id"], p.get("shares") or {}, since, until)
    return panel_state(store, p)


def review_update(store, p):
    s = target_sprint(store, p)
    r = s.setdefault("review", empty_review())
    for k in ("wentWell", "toImprove", "suggestions", "thanks"):
        if k in p:
            r[k] = p[k]
    return panel_state(store, p)


def review_export(store, p):
    s = target_sprint(store, p)
    since, until = review.sprint_range(s)
    rows = review.ticket_rows(s, store.tickets, store.hours_by_key(since, until))
    folder = os.path.expanduser(store.config["reviewDir"])
    os.makedirs(folder, exist_ok=True)
    path = os.path.join(folder, f"{s['label']}.md")
    with open(path, "w", encoding="utf-8") as f:
        f.write(review.markdown(s, rows, review.metrics(rows)))
    return {"_raw": path}


def config_set(store, p):
    for k in CONFIG_KEYS:
        if k in p:
            store.config[k] = str(p[k]).strip()
    return panel_state(store, p)


ACTIONS = {
    "session.info": session_info, "session.sync": lambda s, p: session_info(s, p, sync=True),
    "session.bind": session_bind, "session.unbind": session_unbind, "session.shares": session_shares,
    "tick": tick, "panel.state": panel_state,
    "sprint.new": sprint_new, "sprint.update": sprint_update, "sprint.select": sprint_select, "sprint.sync": sprint_sync,
    "ticket.add": ticket_add, "ticket.update": ticket_update, "ticket.transition": ticket_transition, "points.push": points_push,
    "time.add": time_add, "time.remove": time_remove,
    "review.update": review_update, "review.export": review_export,
    "config.set": config_set,
}
# Their stdout is a path for cubi's `reveal`, so an error must go to stderr with a non-zero exit.
RAW_ACTIONS = {"review.export"}


def main(argv):
    if len(argv) < 2 or argv[1] not in ACTIONS:
        print(json.dumps({"error": f"用法：sprint.py <{'|'.join(ACTIONS)}>"}, ensure_ascii=False))
        return 2
    raw = sys.stdin.read()
    try:
        payload = json.loads(raw) if raw.strip() else {}
    except json.JSONDecodeError as e:
        print(json.dumps({"error": f"stdin 不是 JSON：{e}"}, ensure_ascii=False))
        return 1
    store = Store()
    try:
        result = ACTIONS[argv[1]](store, payload)
    except (JiraError, ValueError) as e:
        result = {"error": str(e)}
    except KeyError as e:
        result = {"error": f"缺少欄位 {e}"}
    except Exception as e:  # noqa: BLE001 — one line for the card, the traceback for the log
        traceback.print_exc(file=sys.stderr)
        result = {"error": f"{type(e).__name__}: {e}"}
    finally:
        store.save()
    if argv[1] in RAW_ACTIONS:
        if "error" in result:
            print(result["error"], file=sys.stderr)
            return 1
        print(result["_raw"])
    else:
        print(json.dumps(result, ensure_ascii=False))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
