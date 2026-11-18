"""Work item actions from the panel that take more than its setting: deleting one and renaming one
(into another there is: the two become one). Neither can be undone from the panel, so the data
files are copied first."""
import copy
import json
import os
import re
import sys
import time
from datetime import datetime

import autopush
import review
from common import rows_for
from items import item_name
from panel import panel_state
from worklog import calendar_left

BACKUPS = "backups"
BACKED_UP = ("sprints.json", "bindings.json", "segments.json")
KEEP = 20
WORK_GAP = 600   # cubi starts a new stretch after this long without activity (SessionStore.workGap)
BACKUP_RE = re.compile(r"\d{8}-\d{6}(-\d+)?-item-(delete|merge)")


def sprint_hours(store):
    """投入 of every sprint, in seconds, read the way the panel reads it."""
    return {s["label"]: review.metrics(rows_for(store, s), store.no_ticket_work(s))["seconds"] for s in store.sprints["sprints"].values()}


def changes(before, after):
    return [{"sprint": label, "before": secs, "after": after.get(label, 0.0)} for label, secs in sorted(before.items()) if abs(after.get(label, 0.0) - secs) >= 1]


def item_seconds(store, name):
    """The item's time the panel shows, over every sprint: its sessions' own and its records."""
    sprints = store.sprints["sprints"].values()
    auto = sum(w["seconds"] for s in sprints for w in store.item_work(s) if w["item"] == name)
    return auto, sum(m["end"] - m["start"] for m in store.segments["manual"] if m.get("item") == name)


def in_use(store, name, now):
    """The sessions whose stretch for the item is open or ended within WORK_GAP: deleting the item
    leaves the rest of that stretch counting nowhere, whatever the session is bound to next."""
    sids = sorted({sid for sid, sess in store.segments["sessions"].items() for seg in sess.values()
                   if seg.get("item") == name and (seg.get("open") or seg["end"] >= now - WORK_GAP)})
    return [store.bindings.get(sid, {}).get("name") or sid[:8] for sid in sids]


def backup(store, data, now, what):
    """A copy of the files the action changes, in the plugin's own data folder (never the repo);
    the newest KEEP copies stay, an older one goes only when it holds nothing but those files."""
    root = store.root / BACKUPS
    stamp = datetime.fromtimestamp(now).strftime("%Y%m%d-%H%M%S")
    folder, n = root / f"{stamp}-item-{what}", 1
    while folder.exists():
        n += 1
        folder = root / f"{stamp}-{n}-item-{what}"
    folder.mkdir(parents=True)
    for name, d in zip(BACKED_UP, data):
        with open(folder / name, "w", encoding="utf-8") as f:
            json.dump(d, f, ensure_ascii=False, indent=1, sort_keys=True)
    ours = sorted((d for d in root.iterdir() if not d.is_symlink() and d.is_dir() and BACKUP_RE.fullmatch(d.name)),
                  key=lambda d: d.lstat().st_mtime)
    for old in ours[:-KEEP]:
        try:
            files = [old / name for name in os.listdir(old)]
            if {f.name for f in files} <= set(BACKED_UP) and all(not f.is_symlink() and f.is_file() for f in files):
                for f in files:
                    f.unlink()
                old.rmdir()
        except OSError as e:
            print(f"backups: left {old.name} as it is: {e}", file=sys.stderr)
    return str(folder).replace(os.path.expanduser("~"), "~", 1)


def item_delete(store, p):
    """From the panel's ✕ on a work item. Without `confirm`: what deleting it would take with it,
    nothing changed. With `confirm` true: the files copied to a backup folder, then the item gone
    with its records, its sessions' bindings and its stamp on their stretches (Store.delete_item)."""
    name = str(p.get("name") or "")
    if name not in store.sprints.get("items", {}):
        raise ValueError(f"沒有「{name}」這個工作項目")
    kept = copy.deepcopy((store.sprints, store.bindings, store.segments))
    touched = [k for m in store.item_footprint(name)["records"] for k in autopush.touched(store, m)]
    before, (auto, booked), using = sprint_hours(store), item_seconds(store, name), in_use(store, name, p.get("now") or time.time())
    held = store.delete_item(name)
    by_sprint = {}
    for m in held["records"]:
        label = store.sprint_of(m)
        by_sprint[label] = by_sprint.get(label, 0) + 1
    on_calendar = sorted((m for m in held["records"] if m.get("calendar")), key=lambda m: m["start"])
    said = {"name": name, "records": len(held["records"]), "recordSeconds": booked, "autoSeconds": auto,
            "bySprint": [{"sprint": label, "records": n} for label, n in sorted(by_sprint.items(), key=lambda kv: (kv[0] is None, kv[0] or ""))],
            "calendar": len(on_calendar), "calendarLeft": calendar_left(on_calendar),
            "sessions": len(held["sessions"]), "inUse": using, "changes": changes(before, sprint_hours(store))}
    if p.get("confirm") is not True:
        store.sprints, store.bindings, store.segments = kept
        state = panel_state(store, p)
        state["itemDelete"] = said
        return state
    said["backup"] = backup(store, kept, time.time(), "delete")
    autopush.queue(store, list(dict.fromkeys(touched)))
    state = panel_state(store, p)
    state["itemDeleted"] = said
    return state


def item_rename(store, p):
    """From the panel's 改名 on a work item: `name` becomes `to` (rules of item_name). When `to` is
    another item already (whatever its case), the two become that one (Store.rename_item): without
    `confirm` that is only said, nothing changed; with it, the files are copied first."""
    if not isinstance(p.get("to"), str):
        raise ValueError("新名字要是文字")
    now = p.get("now") or time.time()                       # a number: check_payload says so
    name, to = str(p.get("name") or ""), item_name(p.get("to"))
    kept = copy.deepcopy((store.sprints, store.bindings, store.segments))
    before, (auto, _) = sprint_hours(store), item_seconds(store, name)
    footprint = store.item_footprint(name)
    kept_name, merged, label = store.rename_item(name, to, now)
    said = {"name": name, "to": kept_name, "merged": merged, "sprint": label, "counted": store.item_counted(kept_name),
            "records": len(footprint["records"]), "autoSeconds": auto, "calendar": sum(1 for m in footprint["records"] if m.get("calendar")),
            "sessions": len(footprint["sessions"]), "changes": changes(before, sprint_hours(store))}
    if merged and p.get("confirm") is not True:
        store.sprints, store.bindings, store.segments = kept
        state = panel_state(store, p)
        state["itemRename"] = said
        return state
    if merged:
        said["backup"] = backup(store, kept, time.time(), "merge")
    state = panel_state(store, p)
    state["itemRenamed"] = said
    return state
