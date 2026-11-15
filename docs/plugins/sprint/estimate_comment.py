"""A ticket whose edit screen has no estimate field: the estimate goes into a 【估點】 comment, and
only after the user has seen the exact words and pressed the button. Cubi edits the one comment it
wrote itself and no other; the number is all that goes in (never the AI's reason)."""
import time

import common
from common import known_key
from jira import JiraError, adf_text
from panel import panel_state
from review import pts

HOW = ("jira", "local", "cancel")


def comment_text(value):
    """The whole comment, in bold (Jade: the number alone, no sentence after it)."""
    return f"【估點】本單 {pts(value)} 點（1 點＝1 人天）"


def comment_doc(value):
    return {"type": "doc", "version": 1, "content": [{"type": "paragraph", "content": [
        {"type": "text", "text": comment_text(value), "marks": [{"type": "strong"}]}]}]}


def no_field_ask(j, key, field, error, mine):
    """Writing the estimate field came back 400 (the lock is not held). It is a ticket for a
    comment only when Jira describes its edit screen and the field is not on it; anything else,
    asking that failing included, is the original error. Returns what the confirmation row shows:
    with Cubi's earlier comment (`mine`), what it says now, or that it is gone."""
    try:
        fields = j.edit_fields(key)
    except JiraError:
        raise error
    if field in fields:
        raise error
    ask = {"edit": None, "old": None, "lost": False, "changed": False}
    if mine:
        try:
            old = adf_text(j.comment(key, mine["id"]).get("body"))
            ask.update(edit=mine["id"], old=old, changed=old != mine.get("text"))
        except JiraError as e:
            if e.code != 404:
                raise
            ask["lost"] = True
    return ask


SENDING_FOR = 60   # longer than one Jira call may take; a mark older than this is from a run that died


def refuse_while_sending(ask):
    if ask and time.time() - ask.get("sending", 0) < SENDING_FOR:
        raise ValueError("這則估點留言正在送出，請稍候")


def same_ask(store, key, ask):
    now = store.tickets.get(key, {}).get("commentAsk")
    return bool(now) and now.get("at") == ask["at"]


def warn(store, p, message):
    state = panel_state(store, p)
    state["warnings"] = state.get("warnings", []) + [message]
    return state


def ask_for(store, key, value, ask):
    store.ticket(key)["commentAsk"] = {**ask, "value": value, "text": comment_text(value), "at": time.time()}


def estimate_comment(store, p):
    """What the user pressed on the confirmation row: "jira" writes the comment (edits Cubi's own
    when there is one), "local" keeps the estimate on this machine only, "cancel" drops the
    question. The number is the one the row showed, never one sent with the click."""
    key = known_key(store, p.get("key"))
    how = p.get("how")
    if how not in HOW:
        raise ValueError("how 要是 jira、local、cancel 其中之一")
    ask = store.tickets[key].get("commentAsk")
    if not ask:
        raise ValueError(f"{key} 沒有在等確認的估點留言")
    if how == "cancel":
        store.ticket(key).pop("commentAsk")
        return panel_state(store, p)
    mine = None
    if how == "jira":
        refuse_while_sending(ask)
        known = store.tickets[key].get("estimateComment")
        if not ask["edit"] and not ask["lost"] and known:
            # Asked before Cubi's comment was written down (it was still on its way): edit that one.
            ask["edit"] = known["id"]
        # Marked and stored before the lock is let go: a second press meanwhile is told to wait
        # instead of writing a second comment.
        ask["sending"] = time.time()
        j, doc = common.jira(store), comment_doc(ask["value"])

        def write():
            if not ask["edit"]:
                return j.add_comment(key, doc)
            try:
                return j.edit_comment(key, ask["edit"], doc)
            except JiraError as e:
                if e.code != 404:
                    raise
                return None
        try:
            written = store.away(write, save_first=True)
        except JiraError:
            if same_ask(store, key, ask):
                store.tickets[key]["commentAsk"].pop("sending", None)
            store.save()
            raise
        same = same_ask(store, key, ask)
        if written is None:
            if not same:
                return panel_state(store, p)
            # Deleted after the row was shown: nothing is written behind the user's back; the row
            # now says a new one would be added, and waits for another press.
            ask_for(store, key, ask["value"], {"edit": None, "old": None, "lost": True, "changed": False})
            return warn(store, p, "Cubi 上次的估點留言在 Jira 上找不到了（可能被刪），沒有寫任何東西；要的話再按一次「留言到 Jira」發一則新的")
        mine = {"id": str(written["id"]), "text": comment_text(ask["value"])}
        if not same:
            # Cancelled or replaced while Jira was asked: the comment is there all the same, so Cubi
            # keeps it to edit next time, and leaves the rest as the user has it now.
            store.ticket(key)["estimateComment"] = mine
            now = store.tickets[key].get("commentAsk")
            if now and not now.get("edit"):   # a question asked meanwhile now edits this one, not adds another
                now.update(edit=mine["id"], old=mine["text"], lost=False, changed=False)
            return warn(store, p, f"估點留言已寫進 Jira（{pts(ask['value'])} 點），但這段時間確認列有變動，本機估點沒有跟著改")
    t = store.ticket(key)
    t["estimate"] = ask["value"]
    t["estimateVia"] = "comment" if mine else "local"
    if mine:
        t["estimateComment"] = mine
    t.pop("commentAsk", None)
    t.pop("suggestion", None)
    return panel_state(store, p)
