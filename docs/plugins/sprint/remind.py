"""The review day's reminders: the one calendar event a sprint gets, and what the card and the
panel say on the day. Only local data is read here; nothing asks Jira."""
import re
from datetime import date, datetime, timedelta

import cadence
from review import parse_date

EVENT_TITLE = "Sprint review"
# After the event is first handed to cubi it is handed over again for this long, then never: a
# write that failed for a moment is made up for, and an event the user has since dragged to the
# real meeting time, moved to another calendar or deleted is not written a second time (cubi only
# looks for its own event around the time it was written at).
SEND_WINDOW = 10 * 60
CLOCK = re.compile(r"([01][0-9]|2[0-3]):([0-5][0-9])")


def marker(sprint):
    return f"sprint:review:{sprint['label']}"


def event_span(day, config):
    """(start, end) of the event on `day` by the settings, or None when no time is set (no event)."""
    m = CLOCK.fullmatch(str(config.get("reviewEventStart") or ""))
    if not m:
        return None
    start = datetime.combine(day, datetime.min.time()) + timedelta(hours=int(m.group(1)), minutes=int(m.group(2)))
    return start.timestamp(), (start + timedelta(minutes=float(config.get("reviewEventMinutes") or 30))).timestamp()


def calendar_event(sprint, config, now):
    """The event to hand to cubi at `now` for the sprint running then, or None. The first time
    (from the sprint's first day to the end of its review day) the day and time are noted on the
    sprint as `reviewEvent`; within SEND_WINDOW the very same event goes again; after that none."""
    if not sprint:
        return None
    sent = sprint.get("reviewEvent")
    if sent is None:
        day, first = cadence.review_day(sprint), parse_date(sprint.get("start"))
        today = date.fromtimestamp(now)
        span = event_span(day, config) if day else None
        if not span or today > day or (first and today < first):
            return None
        sent = sprint["reviewEvent"] = {"at": now, "day": day.isoformat(), "start": span[0], "end": span[1]}
    elif not 0 <= now - sent["at"] <= SEND_WINDOW:
        return None
    return {"title": EVENT_TITLE, "start": sent["start"], "end": sent["end"],
            "notes": f"{sprint.get('name') or sprint['label']} 的 review", "marker": marker(sprint)}


def sprint_on(store, day):
    """The sprint whose days hold `day`, if any."""
    return store.sprint(store.sprint_of({"start": datetime.combine(day, datetime.min.time()).timestamp() + 12 * 3600}) or "")


def is_review_day(sprint, today):
    return bool(sprint) and cadence.review_day(sprint) == today


def is_due(sprint, today):
    """From the review day to the sprint's last day: when the panel offers to write the review."""
    day, end = cadence.review_day(sprint or {}), parse_date((sprint or {}).get("end"))
    return bool(day and end and day <= today <= end)


def moved_hint(sprint):
    """Said once when the review day is no longer the day the calendar event was written for (the
    sprint's end was changed afterwards): the event stays where it is."""
    sent, day = sprint.get("reviewEvent"), cadence.review_day(sprint)
    if not sent or not day or sent["day"] == day.isoformat() or sprint.get("told", {}).get("reviewMoved"):
        return None
    return {"id": f"reviewMoved:{sprint['label']}", "text": f"行事曆上的 review 仍在 {sent['day']}，請手動調整（{sprint['label']} 的 review 日現在是 {day.isoformat()}）。"}
