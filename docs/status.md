# cubi 狀態與進度（2026-11-06）

commit 數與測試數以 `git log` 與 `make test` 為準，這裡不抄數字。Sources 約 6,000 多行 Swift。

## 已完成

| 區塊 | 內容 | 狀態 |
|---|---|---|
| Relay `cubi-hook` | Darwin-only，stdin → unix socket → stdout；blocking 事件等回覆 115 s；statusline 串接（原指令 shell-quote 成單一參數）；`--capture` 錄 payload | 真機驗證 |
| 事件模型 CubiKit | canonical events、`SessionStore` reducer、回覆編碼（allow / always / deny / 問題答案）、`EditSummary` diff、`TranscriptWatcher`、安裝器（備份、diff、CAS 寫入、依 `--agent <id> ` 辨識自己的 hooks） | 單元測試 |
| 島（瀏海） | hidden / compact / expanded；機器人列隨數量變寬並以瀏海為中心（compact 與 expanded 都是整個島往左挪，排比 640 寬才加寬；之前 expanded 置中，五隻以上第一隻被切）；expanded 高度隨內容、有資訊面板時 860 寬；右鍵 app 選單 | 真機驗證；多隻版面離線渲染 4／5／6／8 隻＋Jade 真機五隻展開驗證（2026-11-03） |
| 浮動視窗 | 拖離瀏海即浮動，可放任何螢幕；位置記島頂中心；拔螢幕夾回；拖回頂端 dock；選單切換 | 真機驗證（外接螢幕） |
| 機器人 | 8 種狀態（含 tired）；每 session 一色；右鍵換形狀（方塊／圓／三角／六角）與顏色，記住（UserDefaults `sessionLooks`，200 上限）；翼上拖曳排順序，清單同序，記住（`sessionOrder`） | 單元測試（順序、looks 淘汰、JSON 往返）；載回路徑真機 log；拖曳與重啟後外觀待 Jade 親手試 |
| 審批／問題卡片 | 拒絕／在終端處理／總是允許／允許；AskUserQuestion 選項卡；終端先答或 Esc 自動撤卡；只認同一 tool call 的事件 | 真機驗證 |
| Session 資訊面板 | 專案、模型／effort／版本、開始時間（transcript 建立時間）、使用時間、回合與工具呼叫數、花費、變更行數、context、終端、跳到終端 | 離線渲染驗證；點列待 Jade 親手試 |
| 工作中／晚安／放生 | 沉睡 12 小時（可調）自動進晚安區；右鍵「去睡覺」「起床上班」「放生」；放生後只有送訊息、被問、SessionStart 會回來；兩個集合存 UserDefaults | 放生與拉回真機以 fixture 重播驗證；右鍵待 Jade 親手試 |
| 開新 session | 右鍵「開新 session…」對話框（最近專案／瀏覽、第一句話、接續、終端）、機器人右鍵「再開一個」「在新分頁接續這個 session」（`--resume <id>`）、右翼用量旁的 ＋（compact 就能按）；Ghostty 走 AppleScript `new surface configuration` + `input text`（不用 `initial input`，見已知限制），Terminal.app 走 `do script`；`cubi --new-session` CLI 同一條路 | CLI 真機驗證（Ghostty 帶第一句話 → 4 秒內 SessionStart + prompt；Terminal.app `--continue` → 接到同一個 session；`--resume <id>` 真機驗證；終端開不了時的警告路徑沒驗）；對話框與右鍵待 Jade 親手試 |
| 用量 | 5h / 7d / cost 跨 session 合併，最近活動的 session 才能覆寫 | 真機驗證 |
| 聚焦終端 | Terminal.app（tty）、Ghostty（標題／cwd）、其他 app 只切 app；沒有終端身分時用名稱／cwd 猜 Ghostty 再 Terminal.app；點沉睡的機器人會叫醒 | 有身分路徑真機驗證；猜測路徑只有腳本語法驗證 |
| 安裝器 UI | 設定頁：Claude Code hooks 安裝／解除（看 diff 再寫）、退役舊 notify hook、Agents 開關與 API key、顯示（保持顯示、滑入就展開、機器人大小 28／36／44）、睡眠（沉睡 5–60 分鐘、晚安 1–24 小時或從不；改了立刻 tick：調短立刻生效，調長只有自動進晚安區的會回來、已沉睡的不叫醒）、範圍、插件（Agents／工具） | 真機驗證；三個新設定 Jade 真機驗證（2026-11-03：關滑入展開、切大小後拖曳、沉睡 5 分鐘） |
| Plugin 架構 | `AgentPlugin` 協定；`ClaudeCodePlugin` 內建；`ManifestPlugin` 以 JSON 接新 agent（只能監看） | 單元測試＋假 manifest 真機 |
| 工具插件 | `kind: tool` manifest：HTML 面板 + 白名單指令表（`ToolPlugin` 解析／型別驗證、`ToolPanel` 執行不經 shell、bridge 名可設）；選單與設定頁入口；`cubi --tool-run`；原本寫死在 app 裡的那個管理面板改成 Jade 本機的私用插件（manifest 放 plugins/，不進 repo） | 6 個單元測試；真機 `--tool-run`：私用插件的 status／asset.read 走通、`../x` 與未宣告 action 被擋；面板點擊待 Jade 親手試 |
| session 掛件 | 工具插件選填 `session{info,refresh}`：資訊窗選到 session 時 cubi 把 session（含活動時段）餵 stdin、畫它回的列（可帶連結）與按鈕，「開面板」把 session 注入面板；`$plugin`、相對執行檔、工作目錄＝插件目錄；hook 命令 20 秒逾時（殺整個 process group） | 單元測試（manifest 驗證、PluginIO 上限）；CLI 餵 stdin 走通；真機畫面待 Jade |
| 活動時段 | `SessionInfo.segments`：真事件開段／依 sleepAfter 切段、tick 收段、SessionEnd 收段、叫醒不算；結束／放生的最後一段保留到下一次 tick | 單元測試 |
| 第三輪 dashboard（2026-11-05） | 資訊窗：列的 `tone`／`progress`／`clock`、按鈕 `icon`；sprint 的 ▶／⏸ 計時與估點倒數。面板：樣式包 `panel.style:"cubi"`、sprint 面板 dashboard、草稿機制（打到一半不丟、組字中不重畫、亂序回應）。設定頁：左側導覽＋卡片、淺深兩套、`--render-settings` | 單元測試（PluginIO、sprint 35 個）；`--render-panel --eval` 探針（草稿 20 多個情境）；`--render-settings` 六頁 × 淺深；渲染前後 defaults 不變；點按互動待 Jade |
| 行事曆 | 工具插件選填 `tick{action,every}`：定時餵所有 session，回的 calendar 條目由 `SystemCalendar`（EventKit）寫進設定頁選的行事曆；記號去重、同記號延長、同標題 5 分鐘內合併、每筆 commit、標「空閒」；設定頁「行事曆」區 | `CalendarMerge` 純函式測試；EventKit 真機授權與事件待 Jade |
| sprint 插件 | `docs/plugins/sprint/`：Python 標準庫；Jira 用 netrc；sprint＝標籤（這個 Jira 沒有 Sprint 欄位）；多專案 JQL（預設只抓受託人是自己的）；自動／手動綁單（資訊窗可直接綁／解除）、多單比例分攤、手動時段、transition；實際點數＝時數÷每點小時數（預設 8，可設欄位寫回）；回顧：五卡、任務分類甜甜圈（提早／準時、超時完成、未完成、超時未完成、未估點，點開列單）、burndown、近幾個 sprint、總結＋四段＋感謝、Markdown 匯出；「用 Claude 整理回顧」寫數據檔並開 Claude Code session（內建 `session.new`）寫好後填回 | 19 個 unittest；CLI 對真 Jira：`session.info`／綁單號 input／`sprint.sync {replace}`（新 JQL 抓到 25 張受託人是 Jade 的單）／`review.brief` 產檔走通；面板畫面待 Jade |
| 發佈 | `make bundle` strip debug 符號並守門（執行檔裡不得有 `/Users/…`）；`make dist` 產固定檔名 `Cubi.zip`；`scripts/install.sh` 下載、sha256 完整性校驗、`codesign -R` 比對 cubi-dev 憑證 hash 後才裝並拿掉 quarantine；`ci.yml`／`release.yml`（tag 觸發，從 secrets 匯入 .p12 簽） | 真機驗證：v0.1.0 由 release.yml 在 macos-26 建、簽、掛上 Release（1.5 分鐘）；從 `releases/latest/download/` 抓回來 sha256 與 `codesign -R` 都過、OSO 0、版本 0.1.0 |
| 文件 | README（介紹、機器人表情與島的截圖 `docs/images/`、安裝、操作一覽、解除）、`docs/development.md`（make 目標、CLI、憑證、發版、設計上刻意的事）、`docs/protocol.md`（relay 協定、欄位、manifest 格式）、`docs/plan.md` | 經審查員對帳；圖是 `--render-island` 渲染後裁的 |

舊工具退役：`私用 CLI menubar` 已停並取消登入啟動、`私用 CLI notify off`、`notify-hook.sh` 從 settings.json 移除；保留 `statusline.sh`、`私用 CLI`、`zh-reply-guard.py`。

## 待 Jade 親手驗證

1. 右鍵機器人（翼上或清單列）換形狀／顏色；島空白處右鍵仍是 app 選單。
2. 拖島離開瀏海成浮動視窗、拖回頂端 dock。
3. 點清單列開資訊面板、「跳到終端」、✕ 關閉；看面板哪些列有出現（判斷 2.1.312 實際送了哪些 `cost.*` 欄位）。
4. 右鍵「去睡覺」→ 翼上消失、出現「💤 1」、清單在晚安區；「放生」→ 消失；在那個 session 送一句話 → 回來。
5. 翼上拖一隻機器人換順序 → 清單同序；重啟 Cubi 順序還在；拖機器人時島不會變浮動；右鍵改形狀／顏色後重啟還在。
6. 右鍵「開新 session…」：對話框選專案、填第一句話（含繁中）、開始 → 終端開新分頁、島上出現新機器人；機器人右鍵「在新分頁接續這個 session」。（Jade 已驗：對話框與繁中第一句話 OK）
7. 點改過名的那隻（同目錄還有別的 session 時）→ 跳到它自己的分頁；改名後一分鐘內機器人名字跟著變。
8. 右鍵選單開私用面板走一輪（status、開關、編輯寫入、reveal、pick），行為應與之前一樣。
9. 在另一台沒裝過的機器跑 `curl -fsSL https://raw.githubusercontent.com/jc33654/cubi/main/scripts/install.sh | bash`，看 Automation 授權與機器人是否出現（v0.1.0 已發，secrets 已設）。
10. 資訊窗：選一個名字帶單號的 session，底下有「Sprint · Sprint6」區塊，單號列可點開瀏覽器，「同步 Jira」「開面板」有反應；example-tool 的區塊也在。
11. 設定頁「行事曆」：允許存取 → 選一本行事曆；一分鐘後綁了單的 session 收掉的段出現在行事曆（標題＝單號＋session 名、標空閒、備註最後一行有記號）；重啟 Cubi 不重複；前後 5 分鐘內的段合成一筆。
12. Sprint 面板：Sprint6 已用新 JQL 重抓（25 張受託人是你的單，沒填起訖）——填起訖日期、看「投入」欄的點數、點開各類工時明細、+時數一筆會議勾行事曆、換一個狀態（會真的送 Jira）、回顧分頁點甜甜圈的一類看單、匯出 Markdown 到 Finder。
13. 資訊窗 Sprint 區塊：「綁單號…」跳輸入框、打 `PROJ-xxxx` 綁上；每列尾端的 ✕ 拿掉那張單；沒有 Example Tool 區塊了。
14. 回顧分頁「用 Claude 整理回顧」：先跳確認框（目錄與第一句話）→ 在設定的資料夾開一個 Claude Code 分頁、第一句話叫它讀 `<reviewDir>/Sprint6-data.md`；它跑 `cubi --tool-run sprint review.update -` 時在終端批准；面板每 30 秒查一次，寫好就出現。
15. 浮動視窗拖到外接螢幕：島應跟著過去（拖的時候視窗縮成島大小），放開後再拖回瀏海能 dock。
16. 右鍵選單沒有「Demo 狀態」了。
17. 資訊窗（第三輪）：按鈕是 icon、滑上去有說明；狀態色（工作中藍、思考紫、等你橘、錯誤紅）；Sprint 區塊 ▶ 開始計時 → 「計時中」每秒走、剩餘跟著倒數 → ⏸ 停止 → 面板「手動時段」多一筆「計時」、行事曆一筆、不跟自動段重疊。
18. Sprint 面板（第三輪）：「總覽／回顧／設定」左側導覽；「＋時數」在單底下展開、打到一半切分頁不丟；用注音在回顧欄位打字時，面板 30 秒輪詢不會打斷組字。
19. 設定頁（第三輪）：左側導覽六頁、淺色與深色各看一次；開關與主按鈕是藍色（離線渲染畫不出）；插件頁切一個工具的開關 → 畫面立刻變、「開啟」鈕跟著停用；行事曆頁顯示你實際的權限狀態。在插件頁替一個 agent 按「安裝…」寫入後，卡片按鈕立刻變「更新…／解除…」；設定視窗關掉再開、或切頁，上一次的「已安裝」訊息不再出現。系統通知：第一次打開時在詢問框按「不允許」→ 開關旁出現「沒有權限」；按「打開系統設定」看實際開到哪一頁（目標是通知設定）；在系統設定改成允許後切回 Cubi，標籤消失。
20. 第三輪之後（11-06）：Sprint 總覽「待處理點數」紅字與「排了 X / 容量 Y 點」；session 清單列與資訊窗不再把「思考中」寫兩次（清單離線畫不出，沒驗）；設定窗左上角的方塊 Cubiii 眼睛跟著滑鼠、改任何設定會開心一下、切到別的 app 時停住（都沒驗）。工單表不撐出卡片、＋時數與換狀態按鈕看得到、換狀態的選單浮出來看得到選項；☆／★ 標記（重開面板還在）、點標題排序；對話框與面板裡 ⌘V 能貼上單號（也能貼整個 Jira 網址）；綁單號對話框、設定頁、面板裡各按一次 ⌘Z 能還原；⌘W 關設定窗與面板；點過島之後按 ⌘Q 不會關掉 Cubi（結束走選單列）；資訊窗解除按鈕（已改成每列尾端的 ✕，見第 22 條）。

21. 11-06 下午：sprint 設定頁與設定窗的 ⓘ 滑上去出現說明；滑上去再點 → 固定；固定後再點 ⓘ 本身 → 收起；點別處也收起（設定窗那邊離線畫不出，沒驗）；工單表「★」標題能排序、沒排序時有星號不再自動置頂；「投入」顯示點數、點一下展開各類工時，上方「投入」數字卡點一下展開整個 sprint 的；「實」欄不見了；「寫回 Jira」送的是這張單所有 sprint 的投入換算點數；「沒有單號的工作」記一筆（記在開始時間所在的 sprint；不寫說明會擋、取消勾「計入工時」不加進投入、勾行事曆會出現在行事曆）。
22. 資訊窗：綁 6 張單時每一列尾端都有 ✕，滑上去寫「解除 單號」，點了只拿掉那一張；底部不再有「✕ 單號」按鈕（離線畫過列，底部按鈕列與點擊沒驗）。Sprint 工單表點「投入」展開後，各類合計底下逐筆列出本 sprint 補過的時段與備註（分給多張單的寫出比例）。

## 已知限制

- `cost.total_duration_ms`、`total_api_duration_ms`、`total_lines_*`、`version` 依官方文件解，實錄沒有 statusline 樣本。
- 回合數、工具呼叫數只算 Cubi 看到的；Cubi 重啟歸零。
- Ghostty 的 AppleScript 沒有 tty／pid 可比對（sdef 查過：terminal 只有 id、name、working directory），所以只能靠分頁標題；名字取自 Claude Code 的 `~/.claude/sessions/<pid>.json`（改名立刻有），標題比不到時 cwd 只在唯一時採用。同一目錄多個 session 且都沒名字的話，點了只會把 Ghostty 帶到前面、不切分頁。
- hooks 環境沒有 `TERM_PROGRAM`／tty 的 session（來源不明，log 曾出現）只能用名稱／cwd 猜終端，猜不到就不動。
- 離線渲染（`--render-island`）畫不出 `ScrollView` 內容，清單只能真機看。
- 瀏海面板 1400 pt：翼上 15 隻（含晚安膠囊）起 compact 的島左緣出面板被切；860 寬的資訊面板從同樣隻數起被壓窄到 854，此時機器人那排又會掛出島左緣（渲染 13／14／15 隻驗證：13 隻左緣 45 pt，14 隻 3 pt，15 隻被切）。浮動視窗沒有偏移，不受影響。
- 從瀏海拖出的瞬間島直接出現在滑鼠下方，沒有飛出動畫。
- 沒有 Apple 公證：下載的 app 會被 Gatekeeper 擋，install.sh 驗過簽章後拿掉 quarantine；手動裝的人要右鍵開啟或「隱私與安全性 → 強制打開」。憑證 hash 寫死在 install.sh，換憑證要同步改。
- 開 session：Ghostty 1.3.1 的 AppleScript `initial input` 會把非 ASCII 雙重編碼（繁中變成 `ç¥èåº«` 這種亂碼），所以指令改用 `input text` 打進新分頁（驗證過繁中原樣到達）；`input text` 靠 pty 緩衝，shell 啟動特別慢的機器理論上可能吃掉一截（沒遇過）。
- 開 session：Ghostty 慢到被 5 秒 watchdog 殺掉但分頁其實有開時，退路會在 Terminal.app 再開一個（推論，沒觸發過）。
- 沒有 `git push`（紅線），commit 由 Jade 推（2026-11-03 已推到 117341c，CI 綠）；Coucou 還沒 `brew uninstall --cask coucou`。

## 接下來

工具插件系統 2026-11-03 做完（第一個實例是 Jade 的私用面板，不在 repo）。再來要接其他 agent 的話，下面是現況與查到的事實。

### 額外 agent 插件

### 現在的 plugin 介面能做什麼

`Sources/CubiKit/AgentPlugin.swift`：

| 能力 | ManifestPlugin（純 JSON） | 程式碼 plugin（實作 `AgentPlugin`） |
|---|---|---|
| 監看：session 開始／結束、prompt、工具開始／結束、stop、通知 | ✔ `events.<native>.map` 用 JSON path 對映 | ✔ |
| 安裝 hooks | ✔ `install.mode = json-hooks`（Claude Code 形狀的 JSON）或 `manual` | ✔ 可自訂（TOML、其他格式） |
| 審批／問題卡片 | ✘ 沒有回覆模板，blocking 事件直接交回 agent 自己的提示 | ✔ 實作 `reply(_:for:)` |
| statusline 用量 | 只有 `capabilities: ["statusline"]` 宣告；decode 要產生 `.statusline` 事件 | ✔ |
| 憑證 | ✔ `secrets[]` 存登入鑰匙圈（目前沒有東西在用它） | ✔ |

relay 端：`cubi-hook --agent <id> --event <native>`，信封 `{v, agent, event, tool, pid, ppid, client, payload}`；blocking 判斷寫死 Claude Code 的事件名（`PermissionRequest`、`PreToolUse` + `AskUserQuestion`），**新 agent 要等回覆得加通用旗標（例如 `--blocking`）**。

### 接一個新 agent 要做的事（依序）

1. **確認 agent 的 hook 機制**：有沒有 hook？事件名、stdin payload 形狀、能不能用 stdout 回覆決定、設定檔格式與位置、hook 是否在 session 啟動時快照。沒有 hook 的 agent（純 TUI）只能從 log／transcript 檔案輪詢，另一種架構。
2. **錄 payload**：像 Phase 0 一樣，用 `cubi-hook --agent <id> --event <x> --capture` 把真實 payload 錄進 `~/Library/Application Support/cubi/capture/`，用 `scripts/import-fixtures.py` 洗成 fixtures（需要為非 Claude Code 的 agent 加一個 fixtures 目錄）。
3. **決定 plugin 形式**：只要監看 → manifest 即可，零程式碼；要審批／問題 → 寫 `Sources/CubiKit/<Agent>Plugin.swift`，實作 decode / reply / install，並在 `PluginRegistry.reload()` 的內建清單加上去（目前只有 `ClaudeCodePlugin()`）。
4. **relay 改動**：`isBlocking` 改成由 `--blocking` 旗標（安裝進 hooks 的指令帶上）或 agent 事件表決定；`docs/protocol.md` 同步。
5. **設定頁**：Agents 區已會列出 plugin 的開關、安裝按鈕、secrets 輸入；程式碼 plugin 只要 `installMode` 對，就能用同一套安裝器（jsonHooks）或顯示手動說明（manual）。
6. **驗證**：fixture 單元測試（decode 逐一對照、reply 形狀）、真機重播、真的開那個 agent 跑一輪。

### 候選 agent 的已知事實（2026-11-03 查官方文件，兩個都沒裝在開發機上）

| | OpenAI Codex CLI | Gemini CLI |
|---|---|---|
| 文件 | https://learn.chatgpt.com/docs/hooks（developers.openai.com/codex/hooks 轉過去） | https://geminicli.com/docs/hooks/reference |
| 設定檔 | `~/.codex/hooks.json`（或 `config.toml` 的 `[[hooks.X]]`）、專案 `.codex/` 同名 | `~/.gemini/settings.json` 的 `hooks` 物件（專案 `.gemini/settings.json` 優先） |
| 條目形狀 | `"PreToolUse": [{ "matcher": "Bash", "hooks": [{ "type": "command", "command": "…", "timeout": 30 }] }]`，timeout 秒 | 同形狀，多 `name`／`description`／`sequential`，timeout 毫秒 |
| 事件 | SessionStart／SessionEnd／PreToolUse／**PermissionRequest**／PostToolUse／PreModelRequest／PostModelRequest／PreCompact／PostCompact／UserPromptSubmit／SubagentStart／SubagentStop／Stop／Interrupt | SessionStart／SessionEnd／BeforeTool／AfterTool／BeforeAgent／AfterAgent／BeforeModel／AfterModel／BeforeToolSelection／Notification／PreCompress |
| stdin 共同欄位 | `session_id`、`transcript_path`、`cwd`、`hook_event_name`、`model`；PreToolUse 多 `turn_id`、`tool_name`、`tool_use_id`、`tool_input`、`permission_mode` | `session_id`、`transcript_path`、`cwd`、`hook_event_name`、`timestamp`；工具事件多 `tool_name`、`tool_input` |
| 審批回覆 | `PermissionRequest` → `{"hookSpecificOutput":{"decision":{"behavior":"allow"|"deny","message":…}}}`，不回就走原本提示；PreToolUse 的 `permissionDecision` 支援 allow／deny，`ask` 「parsed but not supported」 | BeforeTool 只能 `decision: allow|deny`（policy，不是回應使用者的審批提示）；沒有 PermissionRequest；`Notification` 純觀測 |
| 問題卡（AskUserQuestion 類） | 文件沒有 | 文件沒有 |
| 旗標 | 預設開；非 managed 的 hook **要在 `/hooks` 審核信任（依 hash）才會跑**，裝完要使用者去按一次 | 文件沒標實驗；舊第三方資料說要開旗標，未查證 |
| 風險 | — | 文件註明 2026-06-18 起免費與 Google One 用戶被換成 Antigravity CLI，Gemini CLI 走向不明 |

結論：Codex 的事件與回覆幾乎是 Claude Code 的鏡像（PermissionRequest、PreToolUse、Stop、SessionStart/End、UserPromptSubmit），用現有 json-hooks 安裝器加一個 timeout 單位與 `PermissionRequest` 回覆模板就能做審批卡；Gemini 只能監看與 policy 擋，做不出「要不要允許」那張卡。
