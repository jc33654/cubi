# 自建套件指南

套件讓你在 Cubi 裡加一個自己的小工具：一個 HTML 面板，加一張面板可以執行的指令表。選填的話，還能在每個 session 的資訊窗掛一塊自己的內容。這份指南用大約 10 分鐘，帶你做出一個會打招呼的套件。

- 逐欄位的規格在 [reference.md](reference.md)。
- 給編輯器和 Claude Code 讀的格式：[manifest.schema.json](manifest.schema.json)、[hook-io.schema.json](hook-io.schema.json)、[bridge.d.ts](bridge.d.ts)。
- 想讓 Claude Code 幫你寫，把 [claude-prompt.md](claude-prompt.md) 貼給它。

下面每一步都照做過一次（Cubi build 195，用暫時的家目錄），結果寫在步驟裡。只有兩步需要在真的 Cubi 視窗上操作，沒有實測，會特別標出來。

## 1. 建資料夾

套件放在 `~/Library/Application Support/cubi/plugins/<id>/`。`id` 只能用小寫英數與 `-`，最多 24 字，**資料夾名必須跟 id 一樣**。

```sh
mkdir -p ~/Library/Application\ Support/cubi/plugins/hello
cd ~/Library/Application\ Support/cubi/plugins/hello
```

## 2. 寫 manifest.json

```json
{
  "schema": 1,
  "kind": "tool",
  "id": "hello",
  "name": "Hello",
  "panel": { "file": "index.html", "width": 480, "height": 320, "style": "cubi" },
  "commands": {
    "greet": { "run": ["/usr/bin/python3", "$plugin/hello.py", "greet", "$1"], "args": ["value"] }
  }
}
```

- `commands` 是面板能叫的指令表。面板只叫得到這裡列的指令，參數會先過型別檢查，而且**不經 shell**。
- `run` 是 argv：`$plugin` 換成套件資料夾，`$1` 換成面板送來的第一個參數。
- `args` 宣告每個參數的型別。`"value"` 是一行字，最多 512 字，不能以 `-` 開頭。要送長文字（多行、超過 512 字）就用 `"text"`，它只能走 stdin：寫 `"args": ["text"], "stdin": 1`，`run` 裡不要再寫 `$1`，腳本從 stdin 讀。
- `"style": "cubi"` 讓面板套用 Cubi 的樣式（`cubi-` 開頭的 class）。

## 3. 寫腳本

`hello.py`：

```python
import sys

if sys.argv[1] == "greet":
    print(f"你好，{sys.argv[2]}")
```

`run` 的第一格是執行檔，所以有兩種寫法：

- 第一格寫直譯器（上面的寫法），腳本放第二格，不需要執行權限。
- 第一格直接寫 `$plugin/hello.py`：那就要 `chmod +x hello.py`，檔案第一行也要有 `#!/usr/bin/env python3`。實測：有 chmod 但少了這一行，指令會失敗，`err` 是「Exec format error」。

第一格只寫 `python3` 這種名字不行，Cubi 不會去 PATH 找。

## 4. 寫面板

`index.html`：

```html
<!doctype html>
<meta charset="utf-8">
<div class="cubi-main">
  <h1 class="cubi-title">Hello</h1>
  <div class="cubi-card cubi-row">
    <input id="who" value="世界">
    <button class="cubi-btn primary" onclick="greet()">打招呼</button>
  </div>
  <pre id="out"></pre>
</div>
<script>
  const bridge = window.webkit?.messageHandlers?.cubi;
  async function greet() {
    try {
      const r = await bridge.postMessage({ action: "greet", args: [document.getElementById("who").value] });
      document.getElementById("out").textContent = r.ok ? r.out : "失敗：" + r.err;
    } catch (e) {
      document.getElementById("out").textContent = "被拒：" + e;
    }
  }
</script>
```

**面板只能是一個 HTML 檔。** Cubi 把它當成字串載入，沒有基底網址，所以同資料夾的 `app.js`、`style.css`、圖片用相對路徑都載不到，要全部寫進這個檔。實測：放一個 `app.js` 用 `<script src="app.js">` 引用，它沒有被載入。

指令跑完會回 `{ok, out, err}`：`ok` 是 exit code 為 0，`out`、`err` 是 stdout 和 stderr。指令不在表裡、或參數不合型別時，Promise 會 reject，原因是一句中文。

## 5. 檢查

```sh
~/Applications/Cubi.app/Contents/MacOS/cubi --validate-plugin ~/Library/Application\ Support/cubi/plugins/hello
```

這一步不會打開 Cubi。它照 Cubi 載入的規則檢查 manifest，再看面板檔和每個執行檔在不在、能不能執行。

- 實測：印出 `可以載入（工具套件 hello：1 個指令）`，結束碼 0。
- 實測：把 `run` 改成 `["$plugin/hello.py", "greet", "$1"]` 而沒有 chmod，會印出 `錯誤：commands.greet：…/hello.py 不能執行（chmod +x，或第一格寫 /usr/bin/python3、腳本放第二格）`，結束碼 1。

也可以不開面板，直接跑一次指令：

```sh
~/Applications/Cubi.app/Contents/MacOS/cubi --tool-run hello greet 世界
```

實測：印出 `{"err":"","ok":true,"out":"你好，世界\n"}`。stderr 另外會有一行 `plugins: …` 的 log，可以忽略。

## 6. 重新載入

打開 Cubi 的設定 › 插件，按「重新載入」。「工具」底下會多一張 Hello 卡片。（未實測：需要在真的 Cubi 上按）

## 7. 打開面板

- 點選單列的 Cubi 圖示（或在島上按右鍵），「設定…」底下會有 Hello。
- 也可以按設定頁 Hello 卡片上的「開啟」。

在框裡打字、按「打招呼」，底下會出現「你好，…」。

- 未實測：從選單打開需要在真的 Cubi 上點。
- 實測：用 `cubi --render-panel hello out.png --eval "greet()"` 在螢幕外畫出面板並按下按鈕，畫面上出現「你好，世界」。

改了 HTML 之後，關掉面板再打開就會重讀。不要用 `location.reload()`，重載只會剩一張空白頁。

## 8. 出錯時看哪裡

- **設定 › 插件**：載入失敗的用紅字寫原因；載入了但有不認得的欄位（多半是拼錯），用黃字列出。
- **log**：`~/Library/Logs/cubi.log` 有 `plugin <資料夾> rejected: …` 與 `plugin <資料夾> warning: …`。
- **`--validate-plugin`**：同樣的原因，不必重新載入。
- 自己要用的欄位請以 `x-` 開頭（例如 `"x-note"`），Cubi 不讀、也不警告。

實測（用暫時的家目錄，離線畫出設定頁）：
- 一份 `schema` 寫成 2 的 manifest，出現紅字「broken：schema：這份 manifest 是第 2 版，這個 Cubi 只認得到第 1 版，請更新 Cubi」。
- 一份 `panel` 裡多寫了 `File` 的，照樣載入，出現黃字「hello：不認得的欄位 panel.File（拼錯了嗎？自己用的欄位請以 x- 開頭）」。

## 9. 選做：在資訊窗掛一塊

在 manifest 加 `session`，再加一個 **hook 命令**。hook 命令的形狀固定是 `"args": ["text"], "stdin": 1`：

```json
  "session": { "info": "session.info" },
  "commands": {
    "greet": { "run": ["/usr/bin/python3", "$plugin/hello.py", "greet", "$1"], "args": ["value"] },
    "session.info": { "run": ["/usr/bin/python3", "$plugin/hello.py", "info"], "args": ["text"], "stdin": 1 }
  }
```

`hello.py` 加一段，讀 stdin 的 session，輸出幾列：

```python
import json
import sys

if sys.argv[1] == "greet":
    print(f"你好，{sys.argv[2]}")
elif sys.argv[1] == "info":
    session = json.load(sys.stdin)
    minutes = sum(s["end"] - s["start"] for s in session["segments"]) // 60
    print(json.dumps({"rows": [["名稱", session["name"]], ["這 7 天", f"{minutes:.0f} 分鐘"]]}, ensure_ascii=False))
```

島上點開一個 session，資訊窗會多一塊 Hello，顯示「名稱」與「這 7 天」兩列。

- 實測：用 `cubi --tool-run hello session.info -` 從 stdin 餵一個 session，輸出兩列。
- 實測：`cubi --render-widget hello "PROJ-12 範例" out.png` 畫出兩列。
- hook 命令 20 秒沒結束會被強制結束，也不要留背景子行程。
- stdin 和 stdout 的完整欄位在 [reference.md](reference.md#session-hook) 與 `hook-io.schema.json`。

## 下一步

- 想看完整的例子：`docs/plugins/sprint/`（Jira 工單、時數、回顧圖表）。
- 哪些欄位承諾相容（stable）、哪些還在變（experimental）：見 [reference.md](reference.md) 的穩定度欄。
- 套件的資料別放在 `plugins/<id>/` 裡（重裝會被覆蓋），放 `~/Library/Application Support/cubi/<id>/` 之類；腳本用家目錄組出這個路徑，例如 Python 的 `os.path.expanduser("~/Library/Application Support/cubi/hello")`。
- 要回一筆以上的資料給面板，讓腳本印 JSON，面板用 `JSON.parse(r.out)` 讀。
