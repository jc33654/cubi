"""Work items: a name of the user's own (「小工具開發」) a session is bound to instead of tickets.

A session has tickets or one work item, never both. The item's time is work with no ticket: the
session's own stretches and its timer, each stamped when it is written with whether the item
counts in the sprint's hours (changing that later moves only what is still running). Kept on this
machine only: never written to Jira, never put on the calendar."""
import re

from hours import SESSION_KIND
from review import sprint_range

# The shape of an issue key. A work item's name may not have one: it would read as a ticket.
KEY_RE = re.compile(r"[A-Z][A-Z0-9_]+-[0-9]+")
ITEM_MAX = 24


def item_name(text):
    """The name as it is kept (spaces squeezed), or ValueError saying why it cannot be one."""
    name = " ".join(str(text or "").split())
    if not name:
        raise ValueError("要綁什麼？填單號，或自己取的工作項目名稱（例如「小工具開發」）")
    if len(name) > ITEM_MAX:
        raise ValueError(f"工作項目名稱最多 {ITEM_MAX} 個字")
    if KEY_RE.search(name.upper()):
        raise ValueError(f"「{name}」看起來像單號，但不是這裡設定的專案；工作項目的名稱不能像單號，請換一個名字")
    return name


class ItemsMixin:
    """Store methods for `sprints["items"]` (name → {counted}) and a binding's `item`."""

    def item_counted(self, name):
        return bool(self.sprints.get("items", {}).get(name, {}).get("counted", False))

    def item_stamp(self, rec):
        """What a stretch written now for this binding carries, or None when it has no item."""
        name = rec.get("item")
        return {"item": name, "counted": self.item_counted(name)} if name else None

    def bind_item(self, sid, name):
        rec = self.bindings.setdefault(sid, {"keys": [], "removed": [], "shares": {}})
        rec["item"] = name
        self.sprints.setdefault("items", {}).setdefault(name, {"counted": False})

    def unbind_item(self, sid):
        self.bindings.get(sid, {}).pop("item", None)

    def set_item_counted(self, name, counted):
        """From now on; the stretch a session of the item is in the middle of follows too."""
        items = self.sprints.get("items", {})
        if name not in items:
            raise ValueError(f"沒有「{name}」這個工作項目")
        items[name]["counted"] = counted
        for sess in self.segments["sessions"].values():
            for seg in sess.values():
                if seg.get("item") == name and seg.get("open"):
                    seg["counted"] = counted

    def item_work(self, sprint):
        """The sprint's automatic time on work items, per item and counted-or-not, without the
        minutes a manual record covers. A sprint without both dates holds none of it."""
        since, until = sprint_range(sprint)
        if since is None or until is None:
            return []
        cuts, out = self.manual_cuts(), {}
        for sess in self.segments["sessions"].values():
            for start, seg in sess.items():
                if not seg.get("item"):
                    continue
                secs = sum(max(0.0, min(hi, until) - max(lo, since)) for lo, hi in self.session_pieces(float(start), seg["end"], cuts))
                if secs > 0:
                    k = (seg["item"], bool(seg.get("counted")))
                    out[k] = out.get(k, 0.0) + secs
        return [{"item": name, "note": name, "counted": counted, "seconds": secs, "kind": SESSION_KIND, "auto": True}
                for (name, counted), secs in sorted(out.items())]

    def no_ticket_work(self, sprint):
        """Everything of the sprint with no ticket: the stretches written by hand or by a timer,
        and the work items' automatic time."""
        return self.other_work(sprint["label"]) + self.item_work(sprint)

    def items_overview(self, sprint):
        """Every work item with its setting and its time in the sprint (automatic and timed)."""
        auto = self.item_work(sprint) if sprint else []
        booked = self.other_work(sprint["label"]) if sprint else []
        out = []
        for name, it in sorted(self.sprints.get("items", {}).items()):
            secs = sum(a["seconds"] for a in auto if a["item"] == name) + sum(m["end"] - m["start"] for m in booked if m.get("item") == name)
            out.append({"name": name, "counted": bool(it.get("counted")), "seconds": secs,
                        "sessions": sum(1 for rec in self.bindings.values() if rec.get("item") == name)})
        return out
