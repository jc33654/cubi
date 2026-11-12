"""Helpers every sprint command shares: Jira access, the payload's session, the target sprint."""
import math
import os
import re
from datetime import date

from jira import TICKET_FIELDS, Jira, JiraError, parse_issue
import review
from store import KEY_RE

FIELD_RE = re.compile(r"customfield_[0-9]+")
# What a payload field must be when it is there at all (None counts as absent). The same name
# means the same thing in every action, so one table covers them.
TEXT, NUMBER, OBJECT, LIST = "文字", "數字", "物件", "清單"
FIELD_KINDS = {"key": TEXT, "input": TEXT, "label": TEXT, "name": TEXT, "goal": TEXT, "start": TEXT, "end": TEXT, "sid": TEXT,
               "notes": TEXT, "note": TEXT, "kind": TEXT, "summary": TEXT, "cwd": TEXT,
               "now": NUMBER, "shares": OBJECT, "session": OBJECT, "sessions": LIST, "segments": LIST}
KIND_OF = {TEXT: str, NUMBER: (int, float), OBJECT: dict, LIST: list}
MAX_EPOCH = 1e11   # the year 5138: far past any clock, well inside what a date can hold


def check_payload(p):
    """Refuse a payload whose fields are of the wrong kind, in words the panel can show: the
    handlers then never meet a list where they expect text."""
    if not isinstance(p, dict):
        raise ValueError("輸入要是 JSON 物件")
    for name, kind in FIELD_KINDS.items():
        v = p.get(name)
        if v is None:
            continue
        if not isinstance(v, KIND_OF[kind]) or isinstance(v, bool) or (kind == NUMBER and not math.isfinite(v)):
            raise ValueError(f"{name} 要是{kind}")
    if p.get("now") is not None and not 0 < p["now"] < MAX_EPOCH:
        raise ValueError("now 要是 epoch 秒")
    # A session's id, a manual entry's, a Jira transition's: text, or a number Jira handed out.
    if isinstance(p.get("id"), (list, dict, bool)):
        raise ValueError("id 要是文字或數字")
    if "session" in p and p["session"] is not None:
        check_payload(p["session"])
    for s in p.get("sessions") or []:
        check_payload(s)
    for seg in p.get("segments") or []:
        if not isinstance(seg, dict) or not all(isinstance(seg.get(k), (int, float)) and not isinstance(seg.get(k), bool) for k in ("start", "end")):
            raise ValueError("segments 的每一段要有數字的 start 與 end")


def known_key(store, key):
    """A key that may go into a Jira write: the exact form of an issue key, of a ticket the plugin
    already holds. Nothing else is ever put into a request path."""
    if not isinstance(key, str) or not KEY_RE.fullmatch(key):
        raise ValueError("單號格式不對（要像 PROJ-12）")
    if key not in store.tickets:
        raise ValueError(f"不認得 {key}：先把它加進 sprint")
    return key


def jira_field(store, name, label, required=False):
    """The Jira field id a setting names: customfield_<digits> only, so a write can never land on
    summary or assignee. Empty is allowed unless `required`."""
    value = str(store.config.get(name) or "").strip()
    if not value and not required:
        return ""
    if not FIELD_RE.fullmatch(value):
        raise ValueError(f"設定的「{label}」要是 customfield_<數字>（例如 customfield_10016）")
    return value


def dry_run():
    """cubi's offline renders (CUBI_RENDER) on the user's real data: draw, but change nothing,
    here or in Jira. With test data (CUBI_SPRINT_DIR) a render may write as usual."""
    return bool(os.environ.get("CUBI_RENDER")) and not os.environ.get("CUBI_SPRINT_DIR")


def jira(store):
    if dry_run():
        raise JiraError("離線渲染不連 Jira")
    return Jira(store.config["site"], store.config["netrc"])


# How many tickets a search did not return are asked for one by one in a single call: from the
# panel, and from a hook (the session card and its 同步 button), which has 20 seconds in all.
CONFIRM_PANEL, CONFIRM_HOOK = 20, 3


def fetch_tickets(store, keys, confirm=CONFIRM_PANEL):
    """Refresh these tickets from Jira; local fields (notes, doneAt, starred) are kept.

    Jira's search leaves out a key it cannot find (deleted, or not visible to this account)
    without a word, so each key the search did not return is asked for by itself: a 404 marks the
    ticket notFound, whether or not it was ever read before; an answer refreshes it (the search
    index was only behind). At most `confirm` of them per call; the rest wait for the next one.
    A ticket marked notFound is not asked about again by a sync (adding it again does)."""
    if not keys:
        return
    if not all(isinstance(k, str) and KEY_RE.fullmatch(k) for k in keys):
        raise ValueError("單號格式不對（要像 PROJ-12）")
    field = jira_field(store, "pointsField", "估點欄位", required=True)
    j = jira(store)
    fields = TICKET_FIELDS + [field]
    try:
        issues = j.search(f"key in ({','.join(keys)})", fields)
    except JiraError as e:
        if e.code != 400:
            raise
        issues = []   # a search that refuses the whole list: every key is then asked for by itself
    seen = set()
    for issue in issues:
        apply_issue(store, parse_issue(issue, field))
        seen.add(issue["key"])
    for key in [k for k in keys if k not in seen][:confirm]:
        try:
            apply_issue(store, parse_issue(j.issue(key, fields), field))
        except JiraError as e:
            if e.code not in (400, 404):
                raise
            not_found(store, key)


def not_found(store, key):
    """Jira does not know this ticket (any more): it stays where it is, marked, and nothing waits
    to be written to it."""
    t = store.ticket(key)
    t["notFound"] = True
    t.pop("hoursPush", None)


FIELD_REFUSED = "cannot be set"


def field_refused(error, field, what):
    """Jira's answer to writing a field the ticket's screen does not have ("Field 'customfield_…'
    cannot be set. It is not on the appropriate screen, or unknown."), in words; the original
    after it. Any other error comes back as it is."""
    if error.code == 400 and field in str(error) and FIELD_REFUSED in str(error):
        return JiraError(f"這張單在 Jira 上不能寫{what}：它的專案或單的類型沒有這個欄位（{field}），或欄位不在編輯畫面上。原始錯誤：{error}", error.code)
    return error


def apply_issue(store, parsed):
    t = store.ticket(parsed["key"])
    was_done = t.get("done")
    t.update({k: parsed[k] for k in ("summary", "status", "statusCategory", "done", "resolutionDate")})
    t.pop("notFound", None)
    if parsed["estimate"] is not None:
        t["estimate"] = parsed["estimate"]
    if parsed["done"] and not was_done and not t.get("doneAt"):
        t["doneAt"] = parsed["resolutionDate"] or date.today().isoformat()
    if not parsed["done"]:
        t["doneAt"] = None


def session_of(p):
    return p.get("session") or p


def target_sprint(store, p):
    """The sprint the payload names, else the current one; a name that does not exist is an error,
    never silently the current sprint."""
    if p.get("label"):
        s = store.sprint(p["label"])
        if not s:
            raise ValueError(f"沒有 sprint「{p['label']}」")
        return s
    s = store.current_sprint()
    if not s:
        raise ValueError("先建一個 sprint")
    return s


pts = review.pts


def rows_for(store, sprint):
    since, until = review.sprint_range(sprint)
    return review.ticket_rows(sprint, store.tickets, store.hours_by_key(since, until), store.hours_per_point(), store.hours_by_key())


# ---------- session hook ----------
