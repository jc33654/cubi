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
    asks cubi (built-in session.new) to open the session with `prompt`."""
    s = target_sprint(store, p)
    directory = os.path.expanduser(store.config["reviewSessionDir"])
    if not os.path.isdir(directory):
        raise ValueError(f"回顧 session 的資料夾不存在：{directory}（設定分頁可改）")
    rows = rows_for(store, s)
    folder = review_dir(store)
    data_path = os.path.join(folder, f"{s['label']}-data.md")
    with open(data_path, "w", encoding="utf-8") as f:
        f.write(review.brief(s, rows, review.metrics(rows, store.other_work(s["label"])), CUBI, os.path.join(folder, f"{s['label']}.md")))
    return {"directory": directory, "prompt": review.brief_prompt(s, data_path), "file": data_path}
