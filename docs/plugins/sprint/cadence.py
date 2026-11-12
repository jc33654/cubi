"""The sprint rhythm: two weeks from a Monday to the second Sunday, review on that last week's
Thursday and planning on its Friday. Everything here only reads dates and proposes; what a
sprint's dates are is still whatever was saved (by hand, or from a proposal)."""
import re
from datetime import date, timedelta

from review import parse_date

LENGTH = 14
TRAILING_NUMBER = re.compile(r"(.*?)([0-9]+)")


def _in_last_week(sprint, weekday):
    """The given weekday (0 Monday) of the week the sprint ends in, kept inside the sprint: a
    sprint ended by hand on a Tuesday has its review that day, not two days after it is over."""
    start, end = parse_date(sprint.get("start")), parse_date(sprint.get("end"))
    if not end:
        return None
    day = min(end - timedelta(days=end.weekday()) + timedelta(days=weekday), end)
    return max(day, start) if start else day


def review_day(sprint):
    return _in_last_week(sprint, 3)


def planning_day(sprint):
    return _in_last_week(sprint, 4)


def next_label(label):
    """Sprint7 → Sprint8, Sprint09 → Sprint10, S7-2 → S7-3; no number at the end: '' (ask)."""
    m = TRAILING_NUMBER.fullmatch(label or "")
    if not m:
        return ""
    head, number = m.groups()
    return head + str(int(number) + 1).zfill(len(number))


def next_sprint(sprint):
    """What the sprint after this one would be: from the first Monday after its end."""
    end = parse_date((sprint or {}).get("end"))
    if not end:
        return None
    start = end + timedelta(days=7 - end.weekday())
    return {"label": next_label(sprint.get("label")), "start": start.isoformat(), "end": (start + timedelta(days=LENGTH - 1)).isoformat()}


def period_at(anchor, today):
    """The start and end of the period holding `today`, counted in two-week steps from the anchor
    (the Monday some sprint began). None when the anchor is missing or still ahead."""
    anchor = parse_date(anchor)
    if not anchor or anchor > today:
        return None
    start = anchor + timedelta(days=(today - anchor).days // LENGTH * LENGTH)
    return {"start": start.isoformat(), "end": (start + timedelta(days=LENGTH - 1)).isoformat()}


def overlapping(sprints, label, start, end):
    """The first other sprint whose days cross [start, end], if any. Sprints without both dates
    never clash."""
    start, end = parse_date(start), parse_date(end)
    if not start or not end:
        return None
    for other in sorted(sprints, key=lambda s: (s.get("start") or "", s["label"])):
        a, b = parse_date(other.get("start")), parse_date(other.get("end"))
        if other["label"] != label and a and b and a <= end and start <= b:
            return other
    return None


def check_dates(sprints, label, start, end):
    """Raises ValueError for dates that cannot be a sprint's: unreadable, backwards, or crossing
    another sprint's days."""
    for name, text in (("開始", start), ("結束", end)):
        if text and not parse_date(text):
            raise ValueError(f"{name}日期格式不對（要像 2026-11-02）")
    if start and end and parse_date(end) < parse_date(start):
        raise ValueError("結束日不能早於開始日")
    clash = overlapping(sprints, label, start, end)
    if clash:
        raise ValueError(f"日期和 {clash['label']}（{clash['start']} – {clash['end']}）重疊")


def weekend_gaps(sprints):
    """Sprints that end on a Friday with the next one starting the Monday after: the two days in
    between belong to neither. [(sprint, the Sunday its end could move to, the next sprint)]."""
    starts = {parse_date(s.get("start")): s for s in sprints if parse_date(s.get("start"))}
    out = []
    for s in sorted(sprints, key=lambda s: (s.get("start") or "", s["label"])):
        end = parse_date(s.get("end"))
        if end and end.weekday() == 4 and end + timedelta(days=3) in starts and starts[end + timedelta(days=3)] is not s:
            out.append((s, end + timedelta(days=2), starts[end + timedelta(days=3)]))
    return out


def started(sprints, today):
    """Sprints made as "the next one" (they wait) whose first day has come, oldest first, each
    with whether today is still inside it: [(sprint, running)]. One whose days all went by with
    cubi closed is no longer waiting for anything, and is not the one to switch to either."""
    out = []
    for s in sorted(sprints, key=lambda s: (s.get("start") or "", s["label"])):
        start, end = parse_date(s.get("start")), parse_date(s.get("end"))
        if s.get("waiting") and start and start <= today:
            out.append((s, not end or today <= end))
    return out


def today():
    return date.today()
