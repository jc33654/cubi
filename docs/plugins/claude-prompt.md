# 寫套件提示範本（給 Claude Code）

把下面整段貼進 Claude Code，改掉 `【】` 裡的內容就能開始。Claude Code 要讀得到這個 repo 的 `docs/plugins/`：在 repo 資料夾裡開，或把路徑換成你 clone 的位置。

---

幫我做一個 Cubi 的工具套件。

【這個套件要做什麼：例如「一個面板，列出 ~/notes 底下最近改過的 10 個 Markdown 檔，點一下用預設 app 打開」】
【套件 id：小寫英數與 -，最多 24 字，例如 recent-notes】

先讀這些檔，照它們做，不要憑印象：

- `docs/plugins/guide.md`：步驟與完整的最小範例。
- `docs/plugins/reference.md`：每個欄位的規則與穩定度。
- `docs/plugins/manifest.schema.json`：manifest 的 JSON Schema。
- `docs/plugins/hook-io.schema.json`：用到 session hook 時，stdin／stdout 的格式。
- `docs/plugins/bridge.d.ts`：面板 JS 能呼叫什麼。

規則：

1. 套件放在 `~/Library/Application Support/cubi/plugins/<id>/`，資料夾名必須等於 manifest 的 `id`，`"kind": "tool"`，`"schema": 1`。
2. 面板是**一個** HTML 檔，js 和 css 全部寫在裡面；同資料夾的其他檔用相對路徑載不到。要好看就用 `"panel": {"style": "cubi"}` 和 `cubi-` 開頭的 class。
3. 面板只能透過 `window.webkit.messageHandlers.cubi.postMessage({action, args})` 叫 manifest `commands` 裡列的指令，回來是 `{ok, out, err}`。指令不經 shell：`run` 是 argv，第一格寫 `/usr/bin/python3`（或其他直譯器的絕對路徑），腳本放第二格用 `$plugin/…`。如果第一格直接寫腳本，就要 chmod +x 並加 shebang。
4. 參數型別優先用 `"value"`（一行字）和 `"text"`（長內容）。`"text"` 只能走 stdin：寫 `"args": ["text"], "stdin": 1`，`run` 裡不要再寫 `$1`，腳本從 stdin 讀；這是 stable 的用法，可以直接用。要回多筆資料就讓腳本印 JSON，面板 `JSON.parse(r.out)`。動作名稱只用小寫英數與 `. _ -`，開頭是英數。
5. 只用 reference.md 標 **stable** 的欄位。真的需要 experimental 的，先跟我說是哪個、為什麼。
6. 套件自己的資料寫在 `~/Library/Application Support/cubi/<id>/`（腳本用家目錄組出這個路徑），不要寫在 `plugins/<id>/` 裡。
7. 寫完執行下面這行，直到印出「可以載入」而且沒有錯誤：
   `~/Applications/Cubi.app/Contents/MacOS/cubi --validate-plugin ~/Library/Application\ Support/cubi/plugins/<id>`
   再用 `~/Applications/Cubi.app/Contents/MacOS/cubi --tool-run <id> <action> <參數>` 每個指令各跑一次，貼出輸出給我看（stderr 那行 `plugins: …` 是 log，可以忽略）。
   最後用 `~/Applications/Cubi.app/Contents/MacOS/cubi --render-panel <id> /tmp/<id>.png` 在螢幕外畫一張面板截圖，打開那張圖看版面對不對。這一步會真的執行面板載入時呼叫的指令。
8. `cubi` 只用 `--validate-plugin`、`--tool-run`、`--render-panel` 這三個模式；不要執行其他模式（`--install-hooks`、`--uninstall-hooks`、`--new-session` 之類），也不要碰 `~/.claude/` 底下的設定。
9. 做完告訴我：到 Cubi 設定 › 插件按「重新載入」，然後從選單列的 Cubi 選單（「設定…」底下）打開面板。
