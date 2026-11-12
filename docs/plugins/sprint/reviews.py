"""Review actions: the four sections, the Markdown export, the brief for a Claude Code session."""
import os

import review
from common import dry_run, rows_for, target_sprint
from panel import panel_state
from store import empty_review

CUBI = "~/Applications/Cubi.app/Contents/MacOS/cubi"


def review_update(store, p):
    s = target_sprint(store, p)
    r = s.setdefault("review", empty_review())
    for k in review.REVIEW_FIELDS:
        if k in p:
            r[k] = p[k]
    return panel_state(store, p)


def review_resend(store, p):
    """Forget that the sprint's calendar event was sent: the next tick writes it for the review
    day and time as they are now. (cubi skips it if the old one still sits at that very time.)"""
    s = target_sprint(store, p)
    s.pop("reviewEvent", None)
    s.get("told", {}).pop("reviewMoved", None)
    return panel_state(store, p)


def cubi_binary():
    """The cubi to write into a command line for the session: the one that is running this (the
    app says which, CUBI_BIN, and lets a restricted session run exactly that path), else where
    it is usually installed."""
    return os.environ.get("CUBI_BIN") or os.path.expanduser(CUBI)


def brief_dir(store):
    """Where data files for a Claude Code session go: the plugin's own data folder, not the
    user's review folder. A restricted session cannot be asked to approve a read, and Claude Code
    wants approval for any path it finds odd (a folder whose name ends in dots, say): this path
    is ours to keep plain."""
    if dry_run():
        raise ValueError("離線渲染不寫回顧檔")
    folder = os.path.join(str(store.root), "briefs")
    os.makedirs(folder, exist_ok=True)
    return folder


def review_dir(store):
    if dry_run():
        raise ValueError("離線渲染不寫回顧檔")
    folder = os.path.expanduser(store.config["reviewDir"])
    os.makedirs(folder, exist_ok=True)
    return folder


def review_export(store, p):
    s = target_sprint(store, p)
    rows = rows_for(store, s)
    path = os.path.join(review_dir(store), f"{s['label']}.md")
    with open(path, "w", encoding="utf-8") as f:
        f.write(review.markdown(s, rows, review.metrics(rows, store.other_work(s["label"]))))
    return {"_raw": path}


def review_brief(store, p):
    """Write the data file for a Claude Code session and say where to open it; the panel then
    asks cubi (built-in session.new) to open a restricted session with `prompt`."""
    s = target_sprint(store, p)
    directory = os.path.expanduser(store.config["reviewSessionDir"])
    if not os.path.isdir(directory):
        raise ValueError(f"回顧 session 的資料夾不存在：{directory}（設定分頁可改）")
    rows = rows_for(store, s)
    folder = brief_dir(store)
    data_path = os.path.join(folder, f"{s['label']}-data.md")
    with open(data_path, "w", encoding="utf-8") as f:
        f.write(review.brief(s, rows, review.metrics(rows, store.other_work(s["label"])), cubi_binary()))
    # The session is opened restricted (the data holds text other people wrote in Jira) and is
    # never asked anything: it may read `readDirs`, run the one action in `allowActions` to hand
    # the result back, and nothing else.
    return {"directory": directory, "prompt": review.brief_prompt(s, data_path), "file": data_path,
            "readDirs": [folder], "allowActions": ["review.update"]}
