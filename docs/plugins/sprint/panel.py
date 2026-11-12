"""The panel's state (what every panel action answers with) and its settings."""
import os
from datetime import date

import review
from common import FIELD_RE, rows_for
from store import empty_review

CONFIG_KEYS = ("site", "netrc", "projectKey", "jql", "pointsField", "actualPointsField", "hoursPerPoint", "reviewDir", "reviewSessionDir")


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
             "bindings": bindings_overview(store, sprint, session),
             "timers": [{"sid": sid, "name": store.bindings.get(sid, {}).get("name", sid[:8]), "start": t["start"],
                         "keys": list(store.timer_shares(sid))} for sid, t in store.segments["timers"].items()]}
    if sprint:
        rows, other = rows_for(store, sprint), store.other_work(sprint["label"])
        state["sprint"] = {**{k: sprint.get(k) for k in ("label", "name", "start", "end", "goal")}, "review": {**empty_review(), **(sprint.get("review") or {})},
                           "tickets": rows, "metrics": review.metrics(rows, other), "other": other, "burndown": review.burndown(sprint, rows),
                           "capacity": review.capacity(sprint, rows, store.hours_per_point()),
                           "categories": list(review.CATEGORIES),
                           "manual": [m for m in store.segments["manual"] if set(m.get("shares") or [m["key"]]) & set(sprint["keys"])]}
    return state


def bindings_overview(store, sprint, session):
    """Bound sessions that worked in the sprint (any time, without sprint dates), are timing now,
    or are the one the panel was opened from."""
    since, until = review.sprint_range(sprint) if sprint else (None, None)
    here = session["id"] if session else None
    return sorted(({"sid": sid, "name": rec.get("name") or sid[:8], "keys": keys, "shares": store.shares(rec)}
                   for sid, rec in store.bindings.items()
                   if (keys := store.bound_keys(rec)) and (sid == here or store.active_in(sid, since, until))), key=lambda b: b["name"])


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
    for name, label, required in (("pointsField", "估點欄位", True), ("actualPointsField", "實際點數欄位", False)):
        if name in new and (new[name] or required) and not FIELD_RE.fullmatch(new[name]):
            raise ValueError(f"「{label}」要是 customfield_<數字>（例如 customfield_10016）" + ("" if required else "，或留空"))
    store.config.update(new)
    return panel_state(store, p)
