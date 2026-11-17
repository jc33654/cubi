"""Time and binding actions: manual stretches, the timer's stop, what a session is bound to."""
import math
import time
from datetime import datetime

import review
from card import session_info
from common import session_of
import autopush
from hours import check_minutes
from items import item_name
from panel import panel_state
from sprints import sprint_at


def time_add(store, p):
    if p.get("key") and not p.get("start"):
        # The quick way for work on a ticket: only how long. It ended now.
        start = time.time() - check_minutes(p.get("minutes")) * 60
    else:
        start = parse_start(p.get("start"))
    if p.get("key"):
        entry = store.add_manual(p["key"], start, p.get("minutes"), p.get("kind", "開發"), p.get("note", ""), p.get("calendar", False))
    else:
        s = sprint_at(store, start) or store.current_sprint()
        if not s:
            raise ValueError("先建一個 sprint")
        if not (p.get("note") or "").strip():
            raise ValueError("沒有單號的工作要寫說明")
        entry = store.add_manual(None, start, p.get("minutes"), p.get("kind", "會議"), p["note"].strip(), p.get("calendar", False),
                                 sprint=s["label"], counted=p.get("counted", True) is not False)
    autopush.queue(store, autopush.touched(store, entry))
    state = panel_state(store, p)
    # What was written and the sprint whose days hold it: the panel says so when that is not the
    # sprint on screen (its hours there do not move).
    label = store.sprint_of(entry)
    held = store.sprint(label) if label else None
    # Work with no ticket counts in its sprint as it is; a ticket only where it is one of the sprint's.
    state["added"] = {"key": entry["key"], "start": entry["start"], "end": entry["end"], "sprint": label,
                      "inSprint": bool(held) and (entry["key"] is None or entry["key"] in held.get("keys", []))}
    return state


def parse_start(text):
    try:
        return datetime.fromisoformat(text).timestamp()
    except (TypeError, ValueError):
        raise ValueError("開始時間格式不對")


# What the panel says after an edit the calendar will not follow.
CALENDAR_STALE = "行事曆上的舊事件不會自動更新，請手動調整或刪除"
# cubi's calendar only ever grows an event it wrote (same start, later end), and the plugin only
# sends stretches that ended in the last 48 hours (store.calendar_entries).
CALENDAR_WINDOW = 48 * 3600


def time_update(store, p):
    """Change a manual stretch: `minutes`, `start`, `kind`, `note`, each only if given. One a
    timer booked (it has `session`) keeps its start, kind and note: its minutes are matched
    against that session's own stretches, and only its length can be corrected."""
    m = next((m for m in store.segments["manual"] if m["id"] == p["id"]), None)
    if m is None:
        raise ValueError("找不到這筆時段")
    timed = bool(m.get("session"))
    start = m["start"]
    if p.get("start"):
        asked = parse_start(p["start"])
        # The panel shows minutes; the stored start has seconds. Under a minute apart: not a move.
        if abs(asked - start) >= 60:
            if timed:
                raise ValueError("計時產生的時段不能改開始時間，只能改長度或刪除")
            start = asked
    length = check_minutes(p["minutes"]) * 60 if p.get("minutes") is not None else m["end"] - m["start"]
    kind = p["kind"] if p.get("kind") else m.get("kind")
    note = p["note"].strip() if p.get("note") is not None else m.get("note", "")
    if timed and (kind != m.get("kind") or note != m.get("note", "")):
        raise ValueError("計時產生的時段只能改長度或刪除")
    if m.get("key") is None and not note:
        raise ValueError("沒有單號的工作要寫說明")
    end = start + length
    changed = (start, end, kind, note) != (m["start"], m["end"], m.get("kind"), m.get("note", ""))
    only_longer = start == m["start"] and end >= m["end"] and (kind, note) == (m.get("kind"), m.get("note", "")) and end >= time.time() - CALENDAR_WINDOW
    stale = bool(m.get("calendar")) and changed and not only_longer
    before = autopush.touched(store, m)
    m.update(start=start, end=end, kind=kind, note=note)
    if changed:
        autopush.queue(store, before + autopush.touched(store, m))
    state = panel_state(store, p)
    if stale:
        state["notices"] = [CALENDAR_STALE]
    return state


def time_remove(store, p):
    autopush.queue(store, [k for m in store.segments["manual"] if m["id"] == p["id"] for k in autopush.touched(store, m)])
    store.remove_manual(p["id"])
    return panel_state(store, p)


def timer_stop(store, p):
    """From the card (the session itself) or the panel (`sid` of any running timer)."""
    from_panel = "session" in p or "sid" in p or "id" not in p
    sid = p.get("sid") or session_of(p).get("id", "")
    entry, note = store.timer_stop(sid, time.time()) if sid else (None, "要停哪個計時？")
    if entry:
        autopush.queue(store, autopush.touched(store, entry))
    if from_panel:
        state = panel_state(store, p)
        if note:
            state["warnings"] = state.get("warnings", []) + [note]
        return state
    out = session_info(store, session_of(p))
    if note:
        out["error"] = note
    return out


def session_bind(store, p):
    """From the panel: `key`; from the card's 綁單號… button: whatever the user typed in `input`.
    Ticket keys bind those tickets; anything else is the name of a work item. A session has
    tickets or one work item, never both."""
    s = session_of(p)
    text = " ".join(str(p.get(f) or "") for f in ("key", "input")).strip()
    rec = store.bindings.get(s["id"], {})
    keys = store.extract_keys(text)
    if keys:
        if rec.get("item"):
            raise ValueError(f"這個 session 綁的是工作項目「{rec['item']}」。單號和工作項目只能二選一：先解除「{rec['item']}」再綁單號")
        for key in keys:
            store.bind(s["id"], key)
    else:
        name = item_name(text)
        bound = store.bound_keys(rec) if rec else []
        if bound:
            raise ValueError(f"這個 session 已綁 {'、'.join(bound)}。單號和工作項目只能二選一：先解除單號再綁「{name}」")
        store.bind_item(s["id"], name)
    return panel_state(store, p) if "session" in p else session_info(store, s)


def session_unbind(store, p):
    """From the panel: `key` (and `sid` from the bindings overview, any session); from the card's
    ✕ buttons: the key cubi passes back as `input`. A work item's name lets the item go."""
    text = " ".join(str(p.get(f) or "") for f in ("key", "input")).strip()
    keys = store.extract_keys(text)
    if p.get("sid"):
        if p["sid"] not in store.bindings:
            raise ValueError("找不到這個 session 的綁定")
        sid = p["sid"]
    else:
        sid = session_of(p)["id"]
    item = store.bindings.get(sid, {}).get("item")
    if item and not keys and " ".join(text.split()) == item:
        store.unbind_item(sid)
    elif keys:
        store.unbind(sid, keys[0])
    else:
        raise ValueError("要解除哪張單或哪個工作項目？")
    return panel_state(store, p) if "session" in p or p.get("sid") else session_info(store, session_of(p))


def item_update(store, p):
    """From the panel: whether work item `name` counts in the sprint's hours, from now on."""
    if not isinstance(p.get("counted"), bool):
        raise ValueError("「算進 sprint 投入」要是開或關")
    store.set_item_counted(str(p.get("name") or ""), p["counted"])
    return panel_state(store, p)


def session_shares(store, p):
    s = session_of(p)
    since = until = None
    if p.get("applyToSprint") and store.current_sprint():
        since, until = review.sprint_range(store.current_sprint())
        since = since or 0
    shares = p.get("shares") or {}
    for v in shares.values():
        try:
            ok = not isinstance(v, bool) and math.isfinite(float(v))
        except (TypeError, ValueError):
            ok = False
        if not ok:
            raise ValueError("分攤要是數字")
    store.set_shares(s["id"], shares, since, until)
    return panel_state(store, p)
