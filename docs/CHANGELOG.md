# 更新紀錄

## v0.2.0

距上一版 v0.1.0（2026-11-02）的變化。

### 新功能

- **從島上開新 Claude Code session**：右翼用量旁的 ＋、右鍵「開新 session…」或 ⌘N。選專案、填第一句話、選新對話或接續，開在你的終端（Ghostty 或 Terminal.app）。
- **機器人可以排順序**：在翼上拖曳換位置，順序、形狀與顏色都會記住。
- **更多設定**：
  - 滑入就展開可以關掉。
  - 機器人大小分小、預設、大。
  - 多久沒動靜進入沉睡（5–60 分鐘）、沉睡多久進晚安區（1–24 小時或從不）。
- **點機器人跳終端更準**：
  - 名字改讀 Claude Code 自己的 session 紀錄，改名立刻生效。
  - 跳不到時，島上會說原因與怎麼辦（例如請用 `/rename` 取名）。
  - Claude app 裡開的 session，找得到對話紀錄時會切到那段對話，找不到就只把 app 叫到前面。
- **浮動的島可以拖到其他螢幕**。
- **工具套件**：一個 HTML 面板加一張指令表就是一個套件，可以在 session 的資訊窗掛一塊內容，也可以定時把事件寫進行事曆。
  - 規格是 schema 1，有相容承諾。
  - 有自建套件指南、JSON Schema，以及給 Claude Code 的提示範本，見 [plugins/guide.md](plugins/guide.md)。
  - 新指令 `cubi --validate-plugin <資料夾>` 可以在載入前檢查。
- **sprint 套件**：Jira 工單、估點與實際、時數、計時、回顧圖表、AI 估點、寫進行事曆。說明在 [plugins/sprint/README.md](plugins/sprint/README.md)。
- **受限模式的 session**：套件把別人寫的文字（例如工單內容）交給 Claude 時，用 Claude Code 的受限模式開，只能執行套件指定的動作。
- **專注獎勵**（預設關）：所有 session 在忙的時間每滿 25 分鐘得一顆星星，在設定頁「專注」打開。
- **設定頁改版**：左側導覽、卡片，淺色深色各一套。
- **Cubi 出現在 Dock 與 ⌘Tab**。點 Dock 圖示時，沒有開著的視窗就打開設定頁。
- **輸入框支援 ⌘V、⌘Z**；⌘W 可以關設定與面板。
- **「重開 Cubi.app」**：裝 Cubi 時一起建立。Cubi 卡住時，從 Spotlight 打開它會換一份新的接手。

### 改變

- 工時切段固定是相隔 10 分鐘，不再跟著「多久沒動靜進入沉睡」的設定。之前記下的時段不重算。
- 島上的提問卡會完整顯示長問題；選項說明可以展開，太長時卡內可以捲動。
- Cubi 在背景時，瀏海上的島也會顯示滑過提示。
- 點島之後按 ⌘Q 不會關掉 Cubi，避免誤關。
- 套件 manifest 的載入規則變嚴：
  - 資料夾名必須等於 `id`。
  - 動作名稱只能用小寫英數與 `. _ -`，開頭是英數。
  - `schema` 寫比 1 大的數字會被拒，請更新 Cubi。
  - 不認得的欄位會在設定頁用黃字警告。
  - 被拒的原因用中文寫在設定頁與 log。
- 命令列只看第一個參數決定做什麼，例如 `cubi --dark --render-settings …` 不再進 render，而是直接開 app。

### 安全性

- 受限模式的 session 不能再在 `cubi --tool-run` 後面加別的旗標（例如開新 session、改 hooks），藉此跳出受限模式。
- 套件 manifest 裡極大的數字不再讓 Cubi 一啟動就當掉。Claude Code 傳來的異常數字也不會讓資訊窗或差異卡當掉。

### 已知限制

- 沒有 Apple 公證：下載的 app 會被 Gatekeeper 擋。安裝腳本驗過簽章後會替你拿掉 quarantine；手動安裝的話，被擋後到「系統設定 › 隱私權與安全性」找到 Cubi，按「強制打開」（依 Apple 2024-08-06 的公告 [Updates to runtime protection in macOS Sequoia](https://developer.apple.com/news/?id=saqachfa)：macOS Sequoia 起不能再用 Control-click（右鍵）「打開」略過，要到系統設定的隱私權與安全性；按鈕字樣取自 macOS 26 的系統設定）。
- **sprint 與範例套件不包在 Cubi.zip 裡**，它們是選用的官方範例。要用 sprint，clone 跟 Cubi 同一版的原始碼（版本要一致）：

  ```sh
  git clone --branch v0.2.0 --depth 1 https://github.com/jc33654/cubi.git
  cd cubi
  scripts/install-plugin.sh docs/plugins/sprint
  ```

  裝完到設定 › 插件按「重新載入」。範例套件同理，把最後一行換成 `scripts/install-plugin.sh docs/plugins/example-tool`。
- 島浮動時，滑過提示不會出現。
- 套件面板只能是一個 HTML 檔，同資料夾的 js、css、圖片載不到。
- 接其他 agent 的 agent 套件還在實驗中，只能監看，審批不會上島。

### 升級注意（從 v0.1.0）

- **hooks 不用重裝**：用 v0.1.0 的安裝程式產生的 `~/.claude/settings.json`，這一版的 `cubi --hooks-status` 回報已安裝，`--hooks-plan` 回報不需要改（實測）。
- **原本的設定都保留**：這一版新增 10 個設定鍵，沒有刪除或改名；每個新鍵沒有值時都有預設值（讀程式碼確認，例如「滑入就展開」預設開、沉睡預設 10 分鐘、晚安預設 12 小時）。
- **relay 會自動更新**：Cubi 啟動時發現 `~/.cubi/bin/cubi-hook` 跟 app 裡的不同就換成新的（讀程式碼確認；真機升級後實際換掉這一步未實測）。
- 用安裝腳本升級：`curl -fsSL https://raw.githubusercontent.com/jc33654/cubi/main/scripts/install.sh | bash`。Automation 授權應該不用重給（推論：依 macOS 以簽章認 app 的規則；未實測）。
- 自己寫過 manifest 的話，先跑 `~/Applications/Cubi.app/Contents/MacOS/cubi --validate-plugin <資料夾>`，看新規則有沒有擋到。
