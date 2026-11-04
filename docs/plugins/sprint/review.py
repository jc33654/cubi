"""Numbers and text for a sprint: totals, burndown, history, and the Markdown export."""
from datetime import date, datetime, timedelta


def fmt_hours(secs):
    if not secs or secs < 60:
        return "–"
    h, m = divmod(int(secs // 60), 60)
    return f"{h}h{m:02d}m" if h else f"{m}m"


def parse_date(text):
    try:
        return date.fromisoformat((text or "")[:10])
    except ValueError:
        return None


def sprint_range(sprint):
    """(since, until) as epoch seconds, end day inclusive; None where the sprint has no date."""
    start, end = parse_date(sprint.get("start")), parse_date(sprint.get("end"))
    since = datetime.combine(start, datetime.min.time()).timestamp() if start else None
    until = datetime.combine(end + timedelta(days=1), datetime.min.time()).timestamp() if end else None
    return since, until


def done_on(ticket):
    return parse_date(ticket.get("doneAt") or ticket.get("resolutionDate"))


def ticket_rows(sprint, tickets, hours):
    rows = []
    for key in sprint.get("keys", []):
        t = tickets.get(key, {"key": key})
        h = hours.get(key, {})
        rows.append({
            "key": key, "summary": t.get("summary", ""), "status": t.get("status", ""), "done": bool(t.get("done")),
            "estimate": t.get("estimate"), "actual": t.get("actual"), "notes": t.get("notes", ""),
            "doneAt": (done_on(t) or date.min).isoformat() if done_on(t) else None,
            "seconds": h.get("total", 0.0), "sessionSeconds": h.get("session", 0.0),
            "manualSeconds": h.get("manual", 0.0), "meetingSeconds": h.get("meeting", 0.0),
        })
    return rows


def metrics(rows):
    estimate = round(sum(r["estimate"] or 0 for r in rows), 2)
    actual = round(sum(r["actual"] or 0 for r in rows), 2)
    seconds = sum(r["seconds"] for r in rows)
    meeting = sum(r["meetingSeconds"] for r in rows)
    done_points = round(sum(r["estimate"] or 0 for r in rows if r["done"]), 2)
    points_for_hours = actual or estimate
    return {
        "tickets": len(rows), "done": sum(1 for r in rows if r["done"]),
        "estimate": estimate, "actual": actual, "donePoints": done_points,
        "ratio": round(actual / estimate, 2) if estimate and actual else None,
        "seconds": seconds, "meetingSeconds": meeting,
        "hoursPerPoint": round(seconds / 3600 / points_for_hours, 1) if points_for_hours else None,
    }


def burndown(sprint, rows, today=None):
    """One point per sprint day: the ideal straight line and what was actually left, by estimate.
    The actual line stops at today."""
    start, end = parse_date(sprint.get("start")), parse_date(sprint.get("end"))
    if not start or not end or end < start:
        return []
    today = today or date.today()
    total = sum(r["estimate"] or 0 for r in rows)
    days = (end - start).days
    out = []
    for i in range(days + 1):
        d = start + timedelta(days=i)
        ideal = round(total * (1 - i / days), 2) if days else 0
        left = None
        if d <= today:
            burnt = sum(r["estimate"] or 0 for r in rows if r["done"] and r["doneAt"] and date.fromisoformat(r["doneAt"]) <= d)
            left = round(total - burnt, 2)
        out.append({"date": d.isoformat(), "ideal": ideal, "actual": left})
    return out


def history(store, limit=4):
    """The last few sprints' headline numbers, oldest first."""
    sprints = sorted(store.sprints["sprints"].values(), key=lambda s: (s.get("start") or "", s["label"]))
    out = []
    for s in sprints[-limit:]:
        since, until = sprint_range(s)
        m = metrics(ticket_rows(s, store.tickets, store.hours_by_key(since, until)))
        out.append({"label": s["label"], "name": s.get("name") or s["label"], "donePoints": m["donePoints"],
                    "estimate": m["estimate"], "actual": m["actual"], "ratio": m["ratio"], "seconds": m["seconds"]})
    return out


def markdown(sprint, rows, m):
    def pts(v):
        return "–" if v is None else (str(int(v)) if float(v).is_integer() else str(v))

    lines = [f"# {sprint.get('name') or sprint['label']} 回顧（{sprint.get('start') or '?'} – {sprint.get('end') or '?'}）", ""]
    if sprint.get("goal"):
        lines += [f"目標：{sprint['goal']}", ""]
    lines += ["## 數據", "", "| 單號 | 摘要 | 狀態 | 估點 | 實際 | 投入時數 |", "|---|---|---|---|---|---|"]
    for r in rows:
        lines.append(f"| {r['key']} | {r['summary']} | {r['status']} | {pts(r['estimate'])} | {pts(r['actual'])} | {fmt_hours(r['seconds'])} |")
    ratio = f"、估/實 {m['ratio']}" if m["ratio"] else ""
    meeting = f"（其中會議 {fmt_hours(m['meetingSeconds'])}）" if m["meetingSeconds"] else ""
    lines += ["", f"合計：估 {pts(m['estimate'])} 點、實際 {pts(m['actual'])} 點、完成 {m['done']}/{m['tickets']}、"
                  f"投入 {fmt_hours(m['seconds'])}{meeting}{ratio}", ""]
    review = sprint.get("review") or {}
    for title, field in (("做得好的地方", "wentWell"), ("需要改善的地方", "toImprove"), ("改善建議", "suggestions")):
        lines += [f"## {title}", ""] + [f"- {item}" for item in review.get(field, []) if item] + [""]
    lines += ["## 想感謝的夥伴", ""]
    lines += [f"- {t.get('who', '')}：{t.get('why', '')}" for t in review.get("thanks", []) if t.get("who") or t.get("why")]
    return "\n".join(lines).rstrip() + "\n"
