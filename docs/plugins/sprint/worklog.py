"""Time and binding actions: manual stretches, the timer's stop, what a session is bound to."""
import math
import time
from datetime import datetime

import review
from card import session_info
from common import session_of
from panel import panel_state
from sprints import sprint_at


def time_add(store, p):
    try:
        start = datetime.fromisoformat(p["start"]).timestamp()
    except (TypeError, ValueError):
        raise ValueError("開始時間格式不對")
    if p.get("key"):
        store.add_manual(p["key"], start, p.get("minutes"), p.get("kind", "開發"), p.get("note", ""), p.get("calendar", False))
    else:
        s = sprint_at(store, start) or store.current_sprint()
        if not s:
            raise ValueError("先建一個 sprint")
        if not (p.get("note") or "").strip():
            raise ValueError("沒有單號的工作要寫說明")
        store.add_manual(None, start, p.get("minutes"), p.get("kind", "會議"), p["note"].strip(), p.get("calendar", False),
                         sprint=s["label"], counted=p.get("counted", True) is not False)
    return panel_state(store, p)


def time_remove(store, p):
    store.remove_manual(p["id"])
    return panel_state(store, p)


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
    """From the panel: `key` (and `sid` from the bindings overview, any session); from the card's
    ✕ buttons: the key cubi passes back as `input`."""
    keys = store.extract_keys(p.get("key", ""), p.get("input", ""))
    if not keys:
        raise ValueError("要解除哪張單？")
    if p.get("sid"):
        if p["sid"] not in store.bindings:
            raise ValueError("找不到這個 session 的綁定")
        store.unbind(p["sid"], keys[0])
        return panel_state(store, p)
    s = session_of(p)
    store.unbind(s["id"], keys[0])
    return panel_state(store, p) if "session" in p else session_info(store, s)


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
