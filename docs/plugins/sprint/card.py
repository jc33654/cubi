"""The session's section of cubi's detail card (`session.info`), its timer, and `tick`."""
import json
import os
import sys
import time
from datetime import date, datetime

import review
from common import fetch_tickets, pts, session_of
from jira import JiraError
from store import ORPHAN_AFTER, remaining_seconds, tone_for


# A timer running longer than this is probably forgotten: the card shows it in red.
LONG_TIMER = 8 * 3600


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
                entry = json.load(f)
            sid, pid = entry.get("sessionId"), entry.get("pid")
        except (OSError, ValueError, AttributeError):
            continue
        # A file left behind by a crashed or killed Claude Code does not keep a timer alive.
        if isinstance(sid, str) and sid and pid_alive(pid):
            ids.add(sid)
    return ids


def pid_alive(pid):
    """True unless `pid` is clearly gone. Not a whole number: unknown, so trusted as alive."""
    if not isinstance(pid, int) or isinstance(pid, bool) or pid <= 0:
        return True
    try:
        os.kill(pid, 0)
    except ProcessLookupError:
        return False
    except (PermissionError, OverflowError):
        return True
    return True


def timer_start(store, p):
    s = session_of(p)
    store.timer_start(s["id"], store.shares(store.binding(s)), time.time())
    return session_info(store, s)
