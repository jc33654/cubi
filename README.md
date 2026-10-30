# cubi

住在 MacBook 瀏海的 Claude Code 小機器人。每個 session 一隻、各自一種顏色，看得出它在做什麼；權限審批與 AskUserQuestion 直接在瀏海上按；右翼顯示 plan 用量（5h / 7d）；context 快滿時會露出疲憊表情。

一個 app 加一個 hook relay，沒有雲端、沒有遙測。資料只在這台機器的 unix socket 上走。

## 需求

- macOS 15 以上（開發機是 macOS 26，有瀏海的螢幕；沒瀏海的螢幕會在頂端置中浮一條小 pill）
- Xcode Command Line Tools（`xcode-select --install`）。**不需要 Xcode.app**
- Swift 6（CLT 內附）
- Claude Code 2.1.312 以上（hook payload 以這個版本實錄為準，見 `docs/protocol.md`）

## 建置與安裝

```
git clone https://github.com/jc33654/cubi.git
cd cubi
make cert      # 檢查簽章憑證，第一次會告訴你怎麼建
make icon      # 由程式自己畫出 app icon（可略過，略過就沒有 icon）
make install   # 建置、打包、簽章、安裝到 ~/Applications/Cubi.app
open ~/Applications/Cubi.app
```

### 第一次：建自簽憑證 `cubi-dev`

沒有 Developer ID 也能用，但要有一張**穩定的**憑證：macOS 的 TCC（Automation、通知授權）認的是「bundle id + 憑證」，ad-hoc 簽章每次重編都會變，授權就會靜默失效。所以一次性在 Keychain Access 建一張：

1. 開 **Keychain Access** → 選單 **Keychain Access → Certificate Assistant → Create a Certificate…**
2. Name：`cubi-dev`；Identity Type：**Self Signed Root**；Certificate Type：**Code Signing**
3. Create。之後 `make cert` 會回報 `identity 'cubi-dev' found`。

沒有這張憑證時 `make install` 會退回 ad-hoc 簽章並印警告，app 仍可用，但每次重編後要重新授權 Automation。

### 其他 make 目標

| 目標 | 做什麼 |
|---|---|
| `make build` / `make release` | debug / release 建置到 `.build/` |
| `make test` | 跑 CubiKit 單元測試（CLT 的 swift-testing 需要額外 rpath，Makefile 已處理） |
| `make bundle` | 只打包簽章到 `build/Cubi.app`，不安裝 |
| `make run` | 安裝並重啟 app |
| `make hook-test` | app 沒開時餵 relay 一筆假資料，必須 exit 0 且無輸出 |

## 第一次執行

1. 啟動後 menubar 會有一個圖示，但 menubar 太滿時 macOS 會把它藏到瀏海後面。**所有選單在島上按右鍵**也有：顯示／收起、保持顯示、系統通知、音效、登入時啟動、設定…、結束。
2. hooks 還沒裝時會自動打開設定視窗。按 **安裝…**，看完 diff 再按 **寫入**。寫入前會先備份到 `~/.claude/backups/cubi/`。
3. **重開已開著的 Claude Code**：hooks 在 session 啟動時讀取，中途改 settings 不生效。status line 則是熱更新。
4. 第一次點機器人跳回終端時，macOS 會跳 **Automation** 授權（控制 Terminal / Ghostty），按允許。
5. 系統通知預設關；在設定頁開啟時 macOS 會問通知授權。

### 裝 hooks 會寫哪些東西

| 位置 | 內容 |
|---|---|
| `~/.claude/settings.json` | 12 個 hook 事件各一組 `cubi-hook` 指令，加 `PreToolUse` 的 `AskUserQuestion` matcher；`statusLine` 包一層：`cubi-hook … statusline --then '<原指令>'`，原指令照常執行、輸出不變 |
| `~/.claude/backups/cubi/settings.json.bak-<時間>` | 每次寫入前的備份 |
| `~/.cubi/bin/cubi-hook` | relay 本體，app 啟動時從 bundle 複製、內容不同就更新；路徑刻意無空白 |
| `~/.cubi/agents/claude-code.json` | 串接前的 `statusLine`，解除安裝時還原 |
| `~/Library/Application Support/cubi/cubi.sock` | app 的 unix socket（0600，只收同 UID） |
| `~/Library/Logs/cubi.log` | 事件與錯誤 log，出問題先看這裡 |

你自己原有的 hooks 不會被動；安裝器只追加自己的條目，解除時只刪自己的。設定頁可勾選「同時移除舊的桌面通知 hook」。

### 命令列

```
~/Applications/Cubi.app/Contents/MacOS/cubi --hooks-status
~/Applications/Cubi.app/Contents/MacOS/cubi --hooks-plan            # 只印 diff，不寫
~/Applications/Cubi.app/Contents/MacOS/cubi --install-hooks         # 印 diff 後寫入（含備份）
~/Applications/Cubi.app/Contents/MacOS/cubi --uninstall-hooks
~/Applications/Cubi.app/Contents/MacOS/cubi --settings              # 啟動 app 並直接開設定頁
```

`--hooks-plan` 與 `--install-hooks` 可加 `--retire-notify`：同時移除舊的 `notify-hook.sh` 桌面通知 hook（設定頁的同一個勾選）。

CLI 跟 app 一樣以 `$HOME` 為家目錄；要對假目錄測就 `HOME=/tmp/x cubi --hooks-plan`。

## 怎麼用

| 動作 | 效果 |
|---|---|
| 滑鼠靠近瀏海 | 島展開成 compact（機器人一排 + 用量） |
| 點島 | expanded：session 清單（名稱、context %、最近一次編輯的 +N −M）、用量列 |
| 點機器人 | 跳到那個 session 的終端分頁（Terminal.app 用 tty、Ghostty 用標題／cwd、其他 app 只切到 app） |
| 有審批 | 島自動打開卡片：**拒絕 / 在終端處理 / 總是允許 / 允許**。「總是允許」會把 Claude Code 自己建議的規則寫進 session 與 `settings.local.json` |
| 有 AskUserQuestion | 每題一組選項按鈕；多選用勾選；也可「在終端回答」 |
| 終端自己答了或按 Esc | 卡片自動收回 |
| session 的 `+N −M` 徽章 | 點開看那次 Edit / Write 的 diff |
| 右鍵 → 保持顯示 | 島不收回，休息時停在 compact |

機器人狀態：idle、thinking（頭頂三點）、working、waiting（跳動 + ! 或 ?）、error（抖一下）、happy（完成後 1.5 秒）、sleeping（10 分鐘無事件）、tired（context ≥ 80%，≥ 90% 描邊紅色脈動）。

音效用 macOS 內建系統音，設定頁可關。

## 設定頁

- **Claude Code**：hooks 與 status line 狀態、安裝／解除、舊 hook 退役選項
- **Agents**：各 agent plugin 開關、安裝按鈕、API key（存登入鑰匙圈）。預設只開 Claude Code
- **顯示**：保持顯示、音效、系統通知、登入時啟動
- **範圍**：忽略哪些目錄開頭的 session（一行一個，可用 `~`）
- **工具箱**：有 `~/.claude-toolkit/panel/index.html` 時才出現，載入原本 ClaudeToolkit 的管理面板

## 多 agent plugin

Claude Code 是內建 plugin。其他 agent 可以用一份 manifest 接進來，放在
`~/Library/Application Support/cubi/plugins/<id>/manifest.json`，在設定頁 Agents 開啟。範例在 `docs/plugins/example-agent/`，欄位說明在 `docs/protocol.md`。

目前 manifest plugin **只能監看**（session、工具開始／結束、結束），它的審批不會出現在島上，會落回那個 agent 自己的提示。要做審批得寫程式碼 plugin（實作 `AgentPlugin` 協定）。

## 解除安裝

1. 設定頁按 **解除安裝…**（或 `cubi --uninstall-hooks`）：移除 Cubi 的 hook 條目、還原 `statusLine`。
2. 「登入時啟動」有開的話先在設定頁關掉。
3. 結束 app，刪 `~/Applications/Cubi.app`、`~/.cubi/`、`~/Library/Application Support/cubi/`、`~/Library/Logs/cubi.log`。
4. 偏好設定：`defaults delete cc.dotdot.cubi`。
5. 有存過 plugin 的 API key 的話，Keychain Access 搜尋 service `cc.dotdot.cubi` 刪掉。
6. `~/.claude/backups/cubi/` 是 settings.json 的歷史備份，可留。

## 開發

```
Sources/CubiKit/     純邏輯：事件模型、解碼、session 狀態機、回覆編碼、安裝器、plugin 協定（可測）
Sources/cubi/        AppKit + SwiftUI app
Sources/cubi-hook/   relay，只 import Darwin，冷啟動個位數 ms
Tests/CubiKitTests/  單元測試；Fixtures/claude-2.1.312/ 是實錄的 hook payload
docs/                plan.md（設計與決策）、protocol.md（relay 協定、欄位、manifest 格式）
```

常用的驗證方式：

- `make test`
- 離線渲染島：`.build/release/cubi --render-island <hidden|compact|expanded|approval|question|usage|usage-compact|diff> <botState> out.png`
- 重播實錄 payload：`python3 -c 'import json;print(json.dumps(json.load(open("Tests/CubiKitTests/Fixtures/claude-2.1.312/SessionStart-1.json"))["payload"]))' | ~/.cubi/bin/cubi-hook --agent claude-code --event SessionStart`
- 錄新版 Claude Code 的 payload：先 `make release`（capture 用的是 `.build/release/cubi-hook`），repo 要在 `$HOME/Documents/cubi`（`docs/capture.settings.local.json` 寫死這個路徑，放別處就改它）。把那份 hooks 放進某個專案的 `.claude/settings.local.json`，跑一輪後用 `scripts/import-fixtures.py <版本>` 匯入（會把路徑洗掉）。錄完要把那些 hooks 拿掉，不然該專案的事件會重複觸發：在 `~/Documents/cubi` 錄的可以在設定頁按「移除」（預設只看這個目錄），在別的專案錄的要自己手動刪。

### 設計上刻意的事

- 協定與做法借自 [Coucou](https://github.com/louis-cfm/coucou)（MIT），程式碼與素材都是自己的。
- relay 等回覆最多 115 秒（hook timeout 120），app 沒開或當掉時 Claude Code 自動退回終端自己問。
- 每條連線一個待決請求，以 fd 為鍵；終端先答了就關連線，卡片跟著收。
- 用量讀數跨 session 合併：只有最近有活動的 session 能覆寫 5h / 7d，閒置 session 送來的空值不會清掉既有數字。
