"""What every data file for a restricted Claude Code session shares: the one command it may run to
hand its answer back, how to write it, and the markers around text other people wrote."""


def write_back_command(cubi, payload, action="review.update"):
    """The one command a restricted session may run, written out in full: this cubi, this plugin's
    `action`, the JSON as its single argument in single quotes. It must begin with the cubi
    path (that is what the app's rule for the session matches on) and be one command: a
    here-document, a pipe, or anything in front of or behind it gets the whole line refused."""
    return f"{cubi} --tool-run sprint {action} '" + payload.replace("'", "'\\''") + "'"


# How to run that command, said in every data file for a restricted session.
WRITE_BACK_RULES = [
    "這個 session 是受限模式，不會問使用者任何事，只有上面這一條指令能執行，而且要完全照這個寫法：",
    "- 整條指令以那個 cubi 的完整路徑開頭，一個字都不要改；**不要在前面加 `cd … &&`**，不需要切換目錄。",
    "- JSON 整段放在一對單引號裡當成一個參數（可以換行）。你寫的文字裡如果有單引號 `'`，要寫成 `'\\''`。",
    "- 只跑這一條：不要拆成多條，後面不要接 `&&`、`;`、`|`，不要用 `cat`、`<<EOF` 或暫存檔。",
]
REFUSED_NOTE = "其他指令與寫檔都會被拒絕，不必嘗試；被拒絕時不要換別的寫法繞過，照上面的寫法重寫一次即可。"


def third_party(text, cell=False):
    """Text other people wrote, made safe to put between the two marker lines: it can never close
    them, and in a table cell it stays on one line."""
    text = str(text or "").replace("<<<", "‹‹‹").replace(">>>", "›››")
    if cell:
        text = text.replace("|", "\\|").replace("\r", " ").replace("\n", " ")
    return text


THIRD_PARTY_OPEN = "<<<第三方資料開始>>>"
THIRD_PARTY_CLOSE = "<<<第三方資料結束>>>"
