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
from store import ORPHAN_AFTER, Store, empty_review, remaining_seconds, tone_for  # noqa: E402

CONFIG_KEYS = ("site", "netrc", "projectKey", "jql", "pointsField", "actualPointsField", "hoursPerPoint", "reviewDir", "reviewSessionDir")
CUBI = "~/Applications/Cubi.app/Contents/MacOS/cubi"
# A timer running longer than this is probably forgotten: the card shows it in red.
LONG_TIMER = 8 * 3600


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
    worked = store.hours_by_key()
    hpp = store.hours_per_point()
    timer = store.timer(p["id"])
    now = time.time()
    rows = []
    for key in keys:
        t = store.tickets.get(key, {})
        secs = worked.get(key, {}).get("total", 0)
        summary = t.get("summary") or ("Jira 查不到這張單" if t.get("notFound") else "（還沒從 Jira 讀到）")
        row = {"label": key, "url": store.browse_url(key)}
        budget = (t.get("estimate") or 0) * hpp * 3600
        left = remaining_seconds(t.get("estimate"), secs, hpp)
        if left is None:
            row["value"] = f"{summary} · 未估點 · 已投入 {review.fmt_hours(secs)}"
        else:
            row.update(tone=tone_for(left, budget), progress=round(min(1.0, max(0.0, secs / budget)), 3))
            if timer is not None and len(timer["shares"]) == 1 and key in timer["shares"]:
                # The running timer burns this ticket's time live: cubi counts it down every second
                # from the timer's start, so this session's own minutes since then are added back
                # (they are the same minutes, and booking the timer will count them once).
                again = store.session_seconds(p["id"], since=timer["start"], key=key)
                row.update(value=summary, clock={"since": timer["start"], "offset": left + again, "down": True})
            else:
                row["value"] = f"{remaining_text(left)} · {summary}"
        rows.append(row)
    if not keys:
        rows.append(["工單", "未綁定；按 ＋ 綁單號"])
    else:
        midnight = datetime.combine(date.today(), datetime.min.time()).timestamp()
        today_secs = store.session_seconds(p["id"], since=midnight)
        rows.append({"label": "今日", "value": review.fmt_hours(today_secs) + (f"（{len(keys)} 張單依比例分）" if len(keys) > 1 else "")})
    if timer:
        long_run = now - timer["start"] > LONG_TIMER
        rows.append({"label": "計時中", "value": "超過 8 小時，忘了停？" if long_run else "",
                     "tone": "danger" if long_run else "info",
                     "clock": {"since": timer["start"], "offset": 0, "down": False}})
    sprint = store.current_sprint()
    actions = [{"label": "綁單號", "action": "session.bind", "input": "要綁的單號（可多個，用空白隔開）", "icon": "link.badge.plus"}]
    if keys:
        # Room for two 解除 buttons under the five-button cap; more tickets than that, the panel.
        actions += [{"label": f"解除 {k}", "action": "session.unbind", "arg": k, "icon": "minus.circle"} for k in keys[:2]]
    # ⏸ whenever a timer runs, bound tickets or not (unbinding the last one must not strand it).
    if timer or keys:
        actions.append({"label": "停止計時並記下" if timer else "開始計時（會議、離開電腦的討論）",
                        "action": "timer.stop" if timer else "timer.start", "icon": "pause.fill" if timer else "play.fill"})
    if keys:
        actions.append({"label": "同步 Jira", "action": "session.sync", "icon": "arrow.triangle.2.circlepath"})
    out = {"title": f"Sprint · {sprint['label']}" if sprint else "Sprint", "rows": rows, "actions": actions[:5]}
    if error:
        out["error"] = error
    return out


def remaining_text(left):
    return f"剩 {review.fmt_hours(left)}" if left >= 0 else f"超 {review.fmt_hours(-left)}"


def tick(store, p):
    now = p.get("now") or time.time()
    for session in p.get("sessions", []):
        rec = store.binding(session)
        store.record_segments(session, store.shares(rec))
    for sid, entry in store.stop_orphan_timers({s["id"] for s in p.get("sessions", [])}, now, claude_session_ids()):
        print(f"timer of session {sid[:8]} stopped: session gone for {ORPHAN_AFTER // 60} min"
              + (f", booked {review.fmt_hours(entry['end'] - entry['start'])}" if entry else ", under a minute, dropped"), file=sys.stderr)
    return {"calendar": store.calendar_entries(now)}


def claude_session_ids():
    """Session ids Claude Code lists as running (~/.claude/sessions/<pid>.json; read only, the
    .key files next to them are never opened). Unreadable means none, never an error."""
    folder = os.path.expanduser(os.environ.get("CUBI_CLAUDE_SESSIONS") or "~/.claude/sessions")
    ids = set()
    try:
        names = os.listdir(folder)
    except OSError:
        return ids
    for name in names:
        if not name.endswith(".json"):
            continue
        try:
            with open(os.path.join(folder, name), encoding="utf-8") as f:
                sid = json.load(f).get("sessionId")
        except (OSError, ValueError, AttributeError):
            continue
        if isinstance(sid, str) and sid:
            ids.add(sid)
    return ids


def timer_start(store, p):
    s = session_of(p)
    store.timer_start(s["id"], store.shares(store.binding(s)), time.time())
    return session_info(store, s)


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
