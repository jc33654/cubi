"""Work items: a name of the user's own (「小工具開發」) a session is bound to instead of tickets.

A session has tickets or one work item, never both. A work item is a ticket with no Jira key:
every record with no ticket is under one (those written before that rule stay under none). Its
time is the sessions' own stretches, its timers and its records, each stamped when it is written
with whether the item counts in the sprint's hours (changing that later moves the whole sprint of
now, never an earlier one). Kept on this machine only: never written to Jira; the sessions' own
stretches never go on the calendar, a record does when it is ticked to."""
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

    def add_item(self, name, counted):
        """A work item made from the panel's 新工作項目, with its first record."""
        self.sprints.setdefault("items", {})[name] = {"counted": bool(counted)}

    def unbind_item(self, sid):
        self.bindings.get(sid, {}).pop("item", None)

    def known_item(self, name, but=None):
        """The item there is under this name whatever its case (other than `but`), or None."""
        fold = name.casefold()
        return next((n for n in self.sprints.get("items", {}) if n != but and n.casefold() == fold), None)

    def rename_item(self, old, new, now):
        """Everything that names `old` names `new` instead (a timer's record says the name in its
        note too). When `new` is another item already (whatever its case) the two become that one,
        with its setting: what of `old` falls in the sprint of now (see set_item_counted) follows
        that setting, earlier sprints keep what they had. Returns (name kept, merged, sprint)."""
        items = self.sprints.get("items", {})
        if old not in items:
            raise ValueError(f"沒有「{old}」這個工作項目")
        if new == old:
            raise ValueError(f"「{old}」已經是這個名字")
        there = self.known_item(new, but=old)
        to = there or new
        label = self.sprint_of({"start": now}) or self.sprints.get("current")
        counted = items[there]["counted"] if there else None
        for sess in self.segments["sessions"].values():
            for start, seg in sess.items():
                if seg.get("item") == old:
                    seg["item"] = to
                    if there and label and self.sprint_of({"start": float(start)}) == label:
                        seg["counted"] = counted
        for m in self.segments["manual"]:
            if m.get("item") == old:
                m["item"] = to
                if m.get("note") == old:
                    m["note"] = to
                if there and label and self.sprint_of(m) == label:
                    m["counted"] = counted
        for rec in self.bindings.values():
            if rec.get("item") == old:
                rec["item"] = to
        items[to] = items[there] if there else items[old]
        del items[old]
        return to, bool(there), label

    def item_footprint(self, name):
        """Everything that names work item `name`: its records (timers' too), the stretches its
        sessions wrote, the sessions bound to it."""
        return {"records": [m for m in self.segments["manual"] if m.get("item") == name],
                "stretches": [seg for sess in self.segments["sessions"].values() for seg in sess.values() if seg.get("item") == name],
                "sessions": [sid for sid, rec in self.bindings.items() if rec.get("item") == name]}

    def delete_item(self, name):
        """The item gone with everything under it: its records, its sessions' bindings to it, and
        its stamp on the stretches they wrote. That time then counts nowhere, like a session bound
        to nothing; `itemDeleted` keeps a session still running from stamping those stretches
        again with whatever it is bound to next (see record_segments, set_shares) — so a stretch
        still open counts nowhere until it ends, whatever the session is bound to meanwhile (the
        rule of every stretch: it keeps what it started with). Returns its footprint."""
        if name not in self.sprints.get("items", {}):
            raise ValueError(f"沒有「{name}」這個工作項目")
        held = self.item_footprint(name)
        if any(sid in self.segments["timers"] for sid in held["sessions"]):
            raise ValueError(f"「{name}」還在計時：先停掉計時再刪")
        ids = {m["id"] for m in held["records"]}
        self.segments["manual"] = [m for m in self.segments["manual"] if m["id"] not in ids]
        for seg in held["stretches"]:
            seg.pop("item")
            seg.pop("counted", None)
            seg["itemDeleted"] = name
        for sid in held["sessions"]:
            self.unbind_item(sid)
        del self.sprints["items"][name]
        return held

    def set_item_counted(self, name, counted, now):
        """For the item's whole sprint that holds `now` (or the one on screen when none does): its
        stretches and timed records starting in it follow, and so does what is written from now on;
        earlier sprints keep what they had. Returns that sprint's label (None without any)."""
        items = self.sprints.get("items", {})
        if name not in items:
            raise ValueError(f"沒有「{name}」這個工作項目")
        items[name]["counted"] = counted
        label = self.sprint_of({"start": now}) or self.sprints.get("current")
        if not label:
            return None
        for sess in self.segments["sessions"].values():
            for start, seg in sess.items():
                if seg.get("item") == name and self.sprint_of({"start": float(start)}) == label:
                    seg["counted"] = counted
        for m in self.segments["manual"]:
            if m.get("item") == name and self.sprint_of(m) == label:
                m["counted"] = counted
        return label

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
