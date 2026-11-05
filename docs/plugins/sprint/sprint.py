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
from card import claude_session_ids, remaining_text, session_info, tick, timer_start  # noqa: E402,F401
from common import apply_issue, fetch_tickets, jira, pts, rows_for, session_of, target_sprint  # noqa: E402,F401
from jira import JiraError, parse_issue, TICKET_FIELDS  # noqa: E402
from store import Store, empty_review  # noqa: E402

CONFIG_KEYS = ("site", "netrc", "projectKey", "jql", "pointsField", "actualPointsField", "hoursPerPoint", "reviewDir", "reviewSessionDir")
CUBI = "~/Applications/Cubi.app/Contents/MacOS/cubi"
def timer_stop(store, p):
    """From the card (the session itself) or the panel (`sid` of any running timer)."""
    from_panel = "session" in p or "sid" in p or "id" not in p
    sid = p.get("sid") or session_of(p).get("id", "")
    _, note = store.timer_stop(sid, time.time()) if sid else (None, "要停哪個計時？")
    if from_panel:
        state = panel_state(store, p)
        if note:
            state["warnings"] = state.get("warnings", []) + [note]
        return state
    out = session_info(store, session_of(p))
    if note:
        out["error"] = note
    return out


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
             "today": date.today().isoformat(), "site": store.config["site"], "warnings": list(store.warnings),
             "timers": [{"sid": sid, "name": store.bindings.get(sid, {}).get("name", sid[:8]), "start": t["start"],
                         "keys": list(t["shares"])} for sid, t in store.segments["timers"].items()]}
    if sprint:
        rows = rows_for(store, sprint)
        state["sprint"] = {**{k: sprint.get(k) for k in ("label", "name", "start", "end", "goal")}, "review": {**empty_review(), **(sprint.get("review") or {})},
                           "tickets": rows, "metrics": review.metrics(rows), "burndown": review.burndown(sprint, rows),
                           "categories": list(review.CATEGORIES),
                           "manual": [m for m in store.segments["manual"] if set(m.get("shares") or [m["key"]]) & set(sprint["keys"])]}
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
    """Pull the sprint's tickets from Jira. `replace` makes the sprint exactly what the JQL
    returns (dropping tickets added by hand or by an earlier, wider query)."""
    s = target_sprint(store, p)
    projects = store.project_keys()
    jql = store.config["jql"].format(projects=", ".join(projects), project=projects[0] if projects else "", label=s["label"])
    field = store.config["pointsField"]
    found = []
    for issue in jira(store).search(jql, TICKET_FIELDS + [field]):
        apply_issue(store, parse_issue(issue, field))
        found.append(issue["key"])
    if p.get("replace"):
        store.set_sprint_keys(s["label"], found)
    else:
        for key in found:
            store.add_to_sprint(s["label"], key)
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
    """From the panel: `key`; from the card's 綁單號… button: whatever the user typed in `input`."""
    s = session_of(p)
    keys = store.extract_keys(p.get("key", ""), p.get("input", ""))
    if not keys:
        raise ValueError(f"沒看到 {'／'.join(store.project_keys())} 的單號")
    for key in keys:
        store.bind(s["id"], key)
    return panel_state(store, p) if "session" in p else session_info(store, s)


def session_unbind(store, p):
    """From the panel: `key`; from the card's 解除 buttons: the key cubi passes back as `input`."""
    s = session_of(p)
    keys = store.extract_keys(p.get("key", ""), p.get("input", ""))
    if not keys:
        raise ValueError("要解除哪張單？")
    store.unbind(s["id"], keys[0])
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
    for k in review.REVIEW_FIELDS:
        if k in p:
            r[k] = p[k]
    return panel_state(store, p)


def review_dir(store):
    folder = os.path.expanduser(store.config["reviewDir"])
    os.makedirs(folder, exist_ok=True)
    return folder


def review_export(store, p):
    s = target_sprint(store, p)
    rows = rows_for(store, s)
    path = os.path.join(review_dir(store), f"{s['label']}.md")
    with open(path, "w", encoding="utf-8") as f:
        f.write(review.markdown(s, rows, review.metrics(rows)))
    return {"_raw": path}


def review_brief(store, p):
    """Write the data file for a Claude Code session and say where to open it; the panel then
    asks cubi (built-in session.new) to open the session with `prompt`."""
    s = target_sprint(store, p)
    directory = os.path.expanduser(store.config["reviewSessionDir"])
    if not os.path.isdir(directory):
        raise ValueError(f"回顧 session 的資料夾不存在：{directory}（設定分頁可改）")
    rows = rows_for(store, s)
    folder = review_dir(store)
    data_path = os.path.join(folder, f"{s['label']}-data.md")
    with open(data_path, "w", encoding="utf-8") as f:
        f.write(review.brief(s, rows, review.metrics(rows), CUBI, os.path.join(folder, f"{s['label']}.md")))
    return {"directory": directory, "prompt": review.brief_prompt(s, data_path), "file": data_path}


def config_set(store, p):
    """Everything is checked before anything is stored, so a bad value leaves the file as it was."""
    new = {}
    for k in CONFIG_KEYS:
        if k in p:
            new[k] = str(p[k]).strip()
    if "hoursPerPoint" in new:
        try:
            new["hoursPerPoint"] = max(0.1, float(new["hoursPerPoint"]))
        except ValueError:
            raise ValueError("每點小時數要是數字")
    if "projectKey" in new and not new["projectKey"]:
        raise ValueError("專案 key 不能空白")
    store.config.update(new)
    return panel_state(store, p)


ACTIONS = {
    "session.info": session_info, "session.sync": lambda s, p: session_info(s, p, sync=True),
    "session.bind": session_bind, "session.unbind": session_unbind, "session.shares": session_shares,
    "review.brief": review_brief, "timer.start": timer_start, "timer.stop": timer_stop,
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
        # Only a run that got through writes anything: a half-done action leaves the files alone.
        store.save()
    except (JiraError, ValueError) as e:
        result = {"error": str(e)}
    except KeyError as e:
        result = {"error": f"缺少欄位 {e}"}
    except Exception as e:  # noqa: BLE001 — one line for the card, the traceback for the log
        traceback.print_exc(file=sys.stderr)
        result = {"error": f"{type(e).__name__}: {e}"}
    finally:
        store.close()
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
