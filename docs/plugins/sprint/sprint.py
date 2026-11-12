#!/usr/bin/env python3
"""cubi sprint plugin: one command per action, JSON in on stdin, JSON out on stdout.

    python3 sprint.py <action> < payload.json

Every action takes the same envelope. From cubi's session hook the payload is the session
itself ({id, name, cwd, …, segments}); from the panel it is whatever the page sends, with the
session (if the panel was opened from one) under "session".

The actions themselves live next door: panel.py, sprints.py, tickets.py, worklog.py, reviews.py
and card.py (the session card, its timer, tick).
"""
import json
import os
import sys
import traceback

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from card import claude_session_ids, session_info, tick, timer_start  # noqa: E402,F401
from common import check_payload, dry_run, jira  # noqa: E402,F401
from jira import JiraError  # noqa: E402
from panel import CONFIG_KEYS, config_set, hint_seen, hours_retry, panel_state  # noqa: E402,F401
from reviews import review_brief, review_export, review_resend, review_update  # noqa: E402
from sprints import sprint_at, sprint_new, sprint_select, sprint_sync, sprint_update  # noqa: E402,F401
from store import Store  # noqa: E402
from tickets import estimate_set, hours_push, points_push, ticket_add, ticket_remove, ticket_transition, ticket_update  # noqa: E402
from worklog import session_bind, session_shares, session_unbind, time_add, time_remove, time_update, timer_stop  # noqa: E402

ACTIONS = {
    "session.info": session_info, "session.sync": lambda s, p: session_info(s, p, sync=True),
    "session.bind": session_bind, "session.unbind": session_unbind, "session.shares": session_shares,
    "review.brief": review_brief, "timer.start": timer_start, "timer.stop": timer_stop,
    "tick": tick, "panel.state": panel_state,
    "sprint.new": sprint_new, "sprint.update": sprint_update, "sprint.select": sprint_select, "sprint.sync": sprint_sync,
    "ticket.add": ticket_add, "ticket.remove": ticket_remove, "ticket.update": ticket_update, "ticket.transition": ticket_transition, "points.push": points_push, "hours.push": hours_push, "hours.retry": hours_retry, "estimate.set": estimate_set,
    "time.add": time_add, "time.update": time_update, "time.remove": time_remove,
    "review.update": review_update, "review.export": review_export, "review.resend": review_resend,
    "config.set": config_set, "hint.seen": hint_seen,
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
        check_payload(payload)
        result = ACTIONS[argv[1]](store, payload)
        # Only a run that got through writes anything: a half-done action leaves the files alone.
        if not dry_run():
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
