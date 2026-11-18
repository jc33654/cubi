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
    before = session_hours(store)
    if p.get("key"):
        entry = store.add_manual(p["key"], start, p.get("minutes"), p.get("kind", "開發"), p.get("note", ""), p.get("calendar", False))
    else:
        s = sprint_at(store, start) or store.current_sprint()
        if not s:
            raise ValueError("先建一個 sprint")
        name, new = record_item(store, p)
        counted = p.get("itemCounted") is True if new else store.item_counted(name)
        entry = store.add_manual(None, start, p.get("minutes"), p.get("kind", "會議"), (p.get("note") or "").strip(), p.get("calendar", False),
                                 sprint=s["label"], counted=counted, item=name)
        if new:
            store.add_item(name, counted)
    autopush.queue(store, autopush.touched(store, entry))
    state = panel_state(store, p)
    # What was written and the sprint whose days hold it: the panel says so when that is not the
    # sprint on screen (its hours there do not move).
    label = store.sprint_of(entry)
    held = store.sprint(label) if label else None
    # `inSprint`: the record itself is in that sprint's hours: a ticket that is one of the sprint's,
    # work with no ticket that counts (its item's setting, stamped on it).
    state["added"] = {"key": entry["key"], "item": entry.get("item"), "newItem": bool(entry.get("item")) and p.get("newItem") is True,
                      "start": entry["start"], "end": entry["end"], "sprint": label,
                      "inSprint": bool(held) and (entry["key"] in held.get("keys", []) if entry["key"] else bool(entry.get("counted"))),
                      "autoPush": bool(autopush.field(store))}
    after = session_hours(store)
    state["added"]["cut"], state["added"]["cutMinor"], state["added"]["cutMinorIn"] = cut_by(before, after, held)
    state["added"]["own"] = overlapped(before, after, entry)
    return state


def record_item(store, p):
    """(name, new): the work item a record with no ticket goes under, one there is or (`newItem`)
    one to make with its 算進 sprint 投入 (`itemCounted`) once the record is written. Every such
    record is under a work item."""
    if not str(p.get("item") or "").strip():
        raise ValueError("補記要掛在一個工作底下：按工單那一列或工作項目那一列的＋，或「新工作項目」")
    name, known, new = item_name(p["item"]), store.sprints.get("items", {}), p.get("newItem") is True
    if new and name in known:
        raise ValueError(f"已有「{name}」：要補記請按它那一列的＋")
    if not new and name not in known:
        raise ValueError(f"沒有「{name}」這個工作項目")
    return name, new


def session_hours(store):
    """What a manual record can take minutes from, keyed (key, item, counted, sprint): each
    ticket's seconds in each sprint's days (sprint None: in no sprint's), and each work item's
    seconds counted in its sprint's hours and not (automatic, and its records). A record under an
    item adds to it what it takes from that item's own sessions, so that item is not said to give way."""
    out, rest = {}, {k: b["total"] for k, b in store.hours_by_key().items()}

    def add(k, secs):
        out[k] = out.get(k, 0.0) + secs
    for s in store.sprints["sprints"].values():
        since, until = review.sprint_range(s)
        if since is None or until is None:
            continue
        for k, b in store.hours_by_key(since, until).items():
            add((k, None, None, s["label"]), b["total"])
            rest[k] = rest.get(k, 0.0) - b["total"]
        for w in store.item_work(s):
            add((None, w["item"], w["counted"], s["label"]), w["seconds"])
    for k, secs in rest.items():
        add((k, None, None, None), secs)
    for m in store.segments["manual"]:
        if m.get("item"):
            add((None, m["item"], bool(m.get("counted")), store.sprint_of(m)), m["end"] - m["start"])
    return out


def cut_by(before, after, held):
    """(what a manual record took minutes from, a minute or more; the seconds it took from those
    it took under a minute from, together, and of them what was in `held`'s hours). A ticket: {key, seconds, inSprint} (its time went down: the record's own ticket's
    never does where the record is); an item: {item, seconds, counted, inSprint}. `inSprint`: those
    minutes were in the hours of `held`, the sprint holding the record (one of its tickets, an item
    counted, in its days); `elsewhere`: they were in another sprint's days, or in no sprint's."""
    label, keys, out, minor = (held or {}).get("label"), set((held or {}).get("keys", [])), [], 0.0
    minor_in = 0.0
    for (key, item, counted, sprint), secs in sorted(before.items(), key=lambda x: tuple(str(v) for v in x[0])):
        gone = secs - after.get((key, item, counted, sprint), 0.0)
        if gone < 1:
            continue
        here = sprint is not None and sprint == label
        e = {"key": key, "seconds": gone, "inSprint": here and key in keys} if key else {"item": item, "seconds": gone, "counted": counted, "inSprint": here and counted}
        if gone >= 60:
            out.append(e if here else {**e, "elsewhere": True})
        else:
            minor += gone
            minor_in += gone if e["inSprint"] else 0.0
    return out, round(minor), round(minor_in)


def overlapped(before, after, entry):
    """Seconds of a manual record its own ticket or item already had (a session's, or an earlier
    record's; never said to give way): its length, less what that ticket or item gained by it, in
    any sprint's days."""
    def own(k):
        return k[0] == entry["key"] if entry["key"] else k[0] is None and k[1] == entry.get("item")
    gained = sum(after.get(k, 0.0) - before.get(k, 0.0) for k in set(before) | set(after) if own(k))
    return round(max(0.0, entry["end"] - entry["start"] - gained))


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
    if m.get("key") is None and not m.get("item") and not note:
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
        if rec.get("item") and rec["item"] != name:
            raise ValueError(f"已綁「{rec['item']}」。一個 session 只能一個工作項目：先解除再綁「{name}」")
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
    """From the panel: whether work item `name` counts in the sprint's hours, for the whole sprint of
    now (earlier ones stay) and what comes after."""
    if not isinstance(p.get("counted"), bool):
        raise ValueError("「算進 sprint 投入」要是開或關")
    name = str(p.get("name") or "")
    label = store.set_item_counted(name, p["counted"], p.get("now") or time.time())
    state = panel_state(store, p)
    held = store.sprint(label) if label else None
    secs = next((it["seconds"] for it in store.items_overview(held) if it["name"] == name), 0.0) if held else 0.0
    state["itemChanged"] = {"name": name, "counted": p["counted"], "sprint": label, "seconds": secs}
    return state


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
