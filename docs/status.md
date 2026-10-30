# cubi 狀態與進度（2026-10-30）

最新 commit `38e40a1`，27 個 commit，Sources 約 6,200 行 Swift，測試 94 個全過。跑著的 app 就是這版。

## 已完成

| 區塊 | 內容 | 狀態 |
|---|---|---|
| Relay `cubi-hook` | Darwin-only，stdin → unix socket → stdout；blocking 事件等回覆 115 s；statusline 串接（原指令 shell-quote 成單一參數）；`--capture` 錄 payload | 真機驗證 |
| 事件模型 CubiKit | canonical events、`SessionStore` reducer、回覆編碼（allow / always / deny / 問題答案）、`EditSummary` diff、`TranscriptWatcher`、安裝器（備份、diff、CAS 寫入、依 `--agent <id> ` 辨識自己的 hooks） | 單元測試 |
| 島（瀏海） | hidden / compact / expanded；機器人列隨數量變寬並以瀏海為中心；expanded 高度隨內容、有資訊面板時 860 寬；右鍵 app 選單 | 真機驗證 |
| 浮動視窗 | 拖離瀏海即浮動，可放任何螢幕；位置記島頂中心；拔螢幕夾回；拖回頂端 dock；選單切換 | 真機驗證（外接螢幕） |
| 機器人 | 8 種狀態（含 tired）；每 session 一色；右鍵換形狀（方塊／圓／三角／六角）與顏色，只記這個 session | 離線渲染驗證；右鍵待 Jade 親手試 |
| 審批／問題卡片 | 拒絕／在終端處理／總是允許／允許；AskUserQuestion 選項卡；終端先答或 Esc 自動撤卡；只認同一 tool call 的事件 | 真機驗證 |
| Session 資訊面板 | 專案、模型／effort／版本、開始時間（transcript 建立時間）、使用時間、回合與工具呼叫數、花費、變更行數、context、終端、跳到終端 | 離線渲染驗證；點列待 Jade 親手試 |
| 用量 | 5h / 7d / cost 跨 session 合併，最近活動的 session 才能覆寫 | 真機驗證 |
| 聚焦終端 | Terminal.app（tty）、Ghostty（標題／cwd）、其他 app 只切 app | 真機驗證 |
| 安裝器 UI | 設定頁：Claude Code hooks 安裝／解除（看 diff 再寫）、退役舊 notify hook、Agents 開關與 API key、顯示、範圍、工具箱面板 | 真機驗證 |
| Plugin 架構 | `AgentPlugin` 協定；`ClaudeCodePlugin` 內建；`ManifestPlugin` 以 JSON 接新 agent（只能監看） | 單元測試＋假 manifest 真機 |
| 文件 | README（建置、憑證、安裝、用法、解除）、`docs/protocol.md`（relay 協定、欄位、manifest 格式）、`docs/plan.md` | 經審查員對帳 |

舊工具退役：`cctl menubar` 已停並取消登入啟動、`cctl notify off`、`notify-hook.sh` 從 settings.json 移除；保留 `statusline.sh`、`cctl`、`zh-reply-guard.py`。

## 待 Jade 親手驗證

1. 右鍵機器人（翼上或清單列）換形狀／顏色；島空白處右鍵仍是 app 選單。
2. 拖島離開瀏海成浮動視窗、拖回頂端 dock。
3. 點清單列開資訊面板、「跳到終端」、✕ 關閉；看面板哪些列有出現（判斷 2.1.312 實際送了哪些 `cost.*` 欄位）。

## 已知限制

- `cost.total_duration_ms`、`total_api_duration_ms`、`total_lines_*`、`version` 依官方文件解，實錄沒有 statusline 樣本。
- 回合數、工具呼叫數只算 Cubi 看到的；Cubi 重啟歸零。
- 形狀／顏色純記憶體：session 消失或 Cubi 重啟就忘（決策）。
- 離線渲染（`--render-island`）畫不出 `ScrollView` 內容，清單只能真機看。
- 從瀏海拖出的瞬間島直接出現在滑鼠下方，沒有飛出動畫。
- 沒有 `git push`（紅線），GitHub 上的 repo 還是空的；Coucou 還沒 `brew uninstall --cask coucou`。

## 接下來：額外插件

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

### 候選 agent 的已知事實（2026-10-30，未查證最新版）

| Agent | hook | 備註 |
|---|---|---|
| OpenAI Codex CLI | `~/.codex/config.toml` 有 `notify` 指令（事件：`agent-turn-complete` 等），沒有審批 hook | 只能監看；TOML 安裝器需要程式碼 plugin 或 `manual` |
| Gemini CLI | 有 hooks 設定（`~/.gemini/settings.json`，事件名與 Claude Code 類似：BeforeTool / AfterTool…） | 形狀接近 json-hooks；審批回覆格式要查 |
| Cursor / Copilot CLI | 不確定 | 要先查 |

要接哪一個先告訴我，第一步是我去查它目前版本的 hook 文件並錄 payload。
