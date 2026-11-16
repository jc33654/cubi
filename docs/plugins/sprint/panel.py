"""The panel's state (what every panel action answers with) and its settings."""
import os
import re
import time
from datetime import date

import autopush
import cadence
import remind
import review
from common import FIELD_RE, rows_for
from store import empty_review

CONFIG_KEYS = ("site", "netrc", "projectKey", "jql", "pointsField", "actualPointsField", "actualHoursField", "autoPushHours", "hoursPerPoint", "cadenceAnchor", "reviewEventStart", "reviewEventMinutes", "reviewDir", "reviewSessionDir", "estimateSessionDir", "estimateRules", "estimateDirs")
ESTIMATE_RULES_MAX = 500


def panel_state(store, p):
    sprint = store.current_sprint()
    session = p.get("session")
    binding = None
    if session:
        rec = store.binding(session)
        binding = {"id": session["id"], "name": session.get("name", ""), "cwd": session.get("cwd"),
                   "keys": store.bound_keys(rec), "auto": rec.get("auto", []), "shares": store.shares(rec)}
    state = {"config": {k: store.config.get(k) for k in CONFIG_KEYS}, "netrcFound": os.path.exists(os.path.expanduser(store.config["netrc"])),
             "sprints": [{"label": s["label"], "name": s.get("name"), "start": s.get("start"), "end": s.get("end"), "waiting": bool(s.get("waiting"))}
                         for s in sorted(store.sprints["sprints"].values(), key=lambda s: (s.get("start") or "", s["label"]))],
             "current": store.sprints.get("current"), "nowSprint": (now := store.sprint_of({"start": time.time()})),
             "nowSprintKeys": (store.sprint(now) or {}).get("keys", []) if now else [], "session": binding, "history": review.history(store),
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
                           # The sprint's tickets' stretches, wherever they fall; sprintOf says which sprint's days hold
                           # each (the reading the hours are counted by), so the panel can say "not in this one".
                           "manual": [{**m, "sprintOf": store.sprint_of(m)} for m in store.segments["manual"]
                                      if set(m.get("shares") or [m["key"]]) & set(sprint["keys"])],
                           "reviewDay": iso(cadence.review_day(sprint)), "planningDay": iso(cadence.planning_day(sprint)),
                           "reviewDue": remind.is_due(sprint, cadence.today()), "reviewEvent": sprint.get("reviewEvent")}
    state.update(proposals(store, sprint), hints=hints(store), hoursPush=autopush.status(store))
    return state


def iso(day):
    return day.isoformat() if day else None


def proposals(store, sprint):
    """What the panel may fill in for the user to confirm: the sprint after the current one
    (unless one already starts that day), and the current period's dates where there are none."""
    sprints = store.sprints["sprints"].values()
    following = cadence.next_sprint(sprint)
    if following and any(s.get("start") == following["start"] or s["label"] == following["label"] for s in sprints):
        following = None
    period = None
    if not sprint or not (sprint.get("start") or sprint.get("end")):
        period = cadence.period_at(store.config.get("cadenceAnchor"), cadence.today())
        if period and cadence.overlapping(sprints, sprint["label"] if sprint else None, period["start"], period["end"]):
            period = None
    return {"nextSprint": following, "period": period}


def hints(store):
    """Things to say once. They stay in the state until the panel answers `hint.seen` for them:
    a state read from the command line (or by a review session) must not use one up unseen."""
    out = []
    for s, sunday, following in cadence.weekend_gaps(store.sprints["sprints"].values()):
        if s.get("told", {}).get("weekendGap"):
            continue
        out.append({"id": f"weekendGap:{s['label']}",
                    "text": f"{s['label']} 的結束日是週五（{s['end']}），{following['label']} 在 {following['start']} 才開始，中間的週末不屬於任何一期，"
                            f"那兩天的工時不會算進哪一期。要算進 {s['label']}，請到「Sprint 資訊」把結束日改成 {sunday.isoformat()}（週日）。"})
    out += [h for h in map(remind.moved_hint, store.sprints["sprints"].values()) if h]
    return out


HINT_KINDS = ("weekendGap", "reviewMoved")


def hint_seen(store, p):
    """The panel showed the hint `id` (`<kind>:<sprint label>`): noted on that sprint, never said again."""
    kind, _, label = str(p["id"]).partition(":")
    s = store.sprint(label)
    if kind not in HINT_KINDS or not s:
        raise ValueError("沒有這個提示")
    s.setdefault("told", {})[kind] = True
    return {"ok": True}


def bindings_overview(store, sprint, session):
    """Bound sessions that worked in the sprint (any time, without sprint dates), are timing now,
    or are the one the panel was opened from."""
    since, until = review.sprint_range(sprint) if sprint else (None, None)
    here = session["id"] if session else None
    return sorted(({"sid": sid, "name": rec.get("name") or sid[:8], "keys": keys, "shares": store.shares(rec)}
                   for sid, rec in store.bindings.items()
                   if (keys := store.bound_keys(rec)) and (sid == here or store.active_in(sid, since, until))), key=lambda b: b["name"])


PROJECT_RE = re.compile(r"[A-Z][A-Z0-9_]*")
# What a restricted session must not open in: the same list cubi keeps from its read folders
# (SessionNewSpec.privateFolders), under the home directory.
PRIVATE_FOLDERS = (".ssh", ".aws", ".gnupg", ".kube", ".docker", ".config/gcloud", ".config/atlassian", "Library/Keychains")


# On a Mac every folder of the data volume also lives under this prefix (a firmlink), which
# realpath does not resolve: /System/Volumes/Data/Users/x/.ssh is ~/.ssh.
FIRMLINK_ROOT = "/System/Volumes/Data"


def _ident(path):
    st = os.stat(path)
    return st.st_dev, st.st_ino


def _upward(path):
    """path, its parent, … up to /."""
    while True:
        yield path
        parent = os.path.dirname(path)
        if parent == path:
            return
        path = parent


def check_code_dir(folder, who):
    """A folder an AI-estimate session may open in and read: it must exist; it may not be or hold
    the home directory (the root, /Users), nor be, hold or sit inside a folder of keys and
    credentials (~/.config holds two of them, ~/Library the keychains). Folders are compared by
    what they are (device and inode), not by how they are written, so neither case (~/.SSH),
    links, nor the firmlink path (/System/Volumes/Data/Users/…) gets past."""
    real = os.path.realpath(os.path.expanduser(folder))
    if not os.path.isdir(real):
        raise ValueError(f"{who}的程式碼資料夾不存在：{folder}")
    home = os.path.realpath(os.path.expanduser("~"))
    private = [p for p in (os.path.join(home, f) for f in PRIVATE_FOLDERS) if os.path.isdir(p)]
    me, keys = _ident(real), {_ident(p) for p in private}
    inside_keys = any(_ident(a) in keys for a in _upward(real) if os.path.isdir(a))
    above = False
    for guarded in [home] + private:
        for way in (guarded, FIRMLINK_ROOT + guarded):   # the two names it goes by, every folder above each
            if os.path.isdir(way) and any(_ident(a) == me for a in _upward(way)):
                above = True
    if inside_keys or above:
        raise ValueError(f"{who}的程式碼資料夾不能是根目錄、家目錄（或它的上層）或放金鑰與憑證的資料夾（或它的上層）：{folder}")


def estimate_dirs(raw):
    """Project key → code folder for the AI estimate; an empty folder drops the project (it then
    uses the default folder). Every folder given must pass check_code_dir."""
    if not isinstance(raw, dict):
        raise ValueError("各專案的程式碼資料夾格式不對")
    out = {}
    for key, folder in raw.items():
        key, folder = str(key).strip().upper(), str(folder or "").strip()
        if not folder:
            continue
        if not PROJECT_RE.fullmatch(key):
            raise ValueError(f"專案代號不對：{key}")
        check_code_dir(folder, f"{key} ")
        out[key] = folder
    return out


def config_set(store, p):
    """Everything is checked before anything is stored, so a bad value leaves the file as it was."""
    new = {}
    for k in CONFIG_KEYS:
        if k in p and k != "estimateDirs":
            new[k] = str(p[k]).strip()
    if "estimateDirs" in p:
        new["estimateDirs"] = estimate_dirs(p["estimateDirs"])
    if "autoPushHours" in new:
        if not isinstance(p["autoPushHours"], bool):
            raise ValueError("「自動寫回時數」要是開或關")
        new["autoPushHours"] = p["autoPushHours"]
    if "hoursPerPoint" in new:
        try:
            new["hoursPerPoint"] = max(0.1, float(new["hoursPerPoint"]))
        except ValueError:
            raise ValueError("每點小時數要是數字")
    if "projectKey" in new and not new["projectKey"]:
        raise ValueError("專案 key 不能空白")
    if new.get("cadenceAnchor"):
        anchor = review.parse_date(new["cadenceAnchor"])
        if not anchor or anchor.isoformat() != new["cadenceAnchor"] or anchor.weekday() != 0:
            raise ValueError("節奏錨點要是某個週一的日期（例如 2026-11-02），或留空")
    if new.get("reviewEventStart") and not remind.CLOCK.fullmatch(new["reviewEventStart"]):
        raise ValueError("review 事件時間要像 10:00，或留空（不寫行事曆）")
    if "reviewEventMinutes" in new:
        try:
            new["reviewEventMinutes"] = float(new["reviewEventMinutes"])
        except ValueError:
            raise ValueError("review 事件長度要是分鐘數")
        if not 5 <= new["reviewEventMinutes"] <= 480:
            raise ValueError("review 事件長度要在 5 到 480 分鐘之間")
    if new.get("estimateSessionDir"):
        check_code_dir(new["estimateSessionDir"], "AI 估點預設")
    if "estimateRules" in new:
        new["estimateRules"] = rules = new["estimateRules"].replace("\r\n", "\n")
        if len(rules) > ESTIMATE_RULES_MAX:
            raise ValueError(f"補充估點規則太長：{len(rules)} 字，要在 {ESTIMATE_RULES_MAX} 字內")
        if "<<<" in rules or ">>>" in rules:
            raise ValueError("補充估點規則不能有 <<< 或 >>>：資料檔用它們圈出別人寫的原文")
    for name, label, required in (("pointsField", "估點欄位", True), ("actualPointsField", "實際點數欄位", False), ("actualHoursField", "實際時數欄位", False)):
        if name in new and (new[name] or required) and not FIELD_RE.fullmatch(new[name]):
            raise ValueError(f"「{label}」要是 customfield_<數字>（例如 customfield_10016）" + ("" if required else "，或留空"))
    store.config.update(new)
    return panel_state(store, p)


def hours_retry(store, p):
    """Tickets whose hours Jira refused wait again; the next tick tries them."""
    autopush.retry(store)
    return panel_state(store, p)
