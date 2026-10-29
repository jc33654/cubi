# Cubi：Claude Code 瀏海小機器人（自製版）實作計畫

## Context

Jade 想要一個住在 MacBook 瀏海的 Claude Code 伴侶：每個 session 一隻小機器人，看得出狀態、能在瀏海上按 Allow / Deny、回答 AskUserQuestion、看 plan 用量、context 快滿時露出疲憊表情。原本評估 fork Coucou（louis-cfm/coucou），結論是：Coucou 核心 4009 行 `HookServer.swift`、上游每週大改、名稱與角色不可用、功能九成用不到，所以改成**自己做新的**，只借 Coucou 的做法與協定（MIT），不借程式碼本體與資產。

已定案的需求（2026-10-28 對話）：

| # | 需求 | 備註 |
|---|---|---|
| 1 | Session 監看：pill + 狀態 + ticker | 每 session 不同顏色，讓使用者分得出「現在是哪個對話」 |
| 2 | 權限審批卡片 Allow / Deny / Always | 終端 session **預設開**（Coucou 預設關） |
| 3 | AskUserQuestion 選項卡片 | Claude Code 2.1.312，支援 |
| 4 | Plan 用量 5h / 7d，取代現有 menubar 用量 | 來源：statusLine 串接 |
| 5 | 桌面通知點擊聚焦 terminal 分頁 | Apple Terminal（tty）、Ghostty（cwd / 標題）、VS Code（app 層級）；可新增 |
| 6 | cctl 管理面板併入同一個 app | 現有 `~/.claude-toolkit/panel/`（Panel.swift 456 行 + index.html） |
| 7 | 檔案 diff 檢視 | PostToolUse 的 Edit / Write |
| 8 | 多 agent 做成 plugin，預設全關，手動開 + 綁憑證 | 第一版只做 Claude Code 內建 plugin，把介面做對 |
| 9 | 角色 | 導角小方塊，程式碼畫，每 session 一色；狀態：idle / thinking / working / waiting / error / sleeping / happy / **tired（context 快滿）** |

其他決策：名稱 **cubi**，bundle id `cc.dotdot.cubi`；要 menubar 圖示；音效先用 macOS 內建系統音（無素材就不做）；外接螢幕頂端置中浮一條 pill；先自用（ad-hoc 簽），之後放 GitHub 給同事自行建置；語言 Swift（AppKit + SwiftUI），SwiftPM，**不用 Xcode**；Coucou 留到 MVP 完成再移除，不裝它的 hooks；repo `https://github.com/jc33654/cubi.git`（已建、空、public），本機 `~/Documents/cubi`。

## 環境事實（已驗證）

- macOS 26.6，M1 Pro，Command Line Tools only，`swift build` 可建 AppKit + SwiftUI 可執行檔（已實測）。
- 內建螢幕 1512×982 有瀏海（`safeAreaInsets.top` 32pt）且為主螢幕；外接 SA272U 2560×1440 無瀏海。
- Claude Code 2.1.312；現有 hooks：Notification → `~/.claude/notify-hook.sh`、Stop → `~/.claude/hooks/zh-reply-guard.py`；statusLine → `~/.claude/statusline.sh`（寫 `/tmp/claude-sessions/<session_id>`（名稱、tty）與 `~/.claude-toolkit/usage.json`）。
- Ghostty 1.3.1 有 AppleScript 字典：window → tab → terminal；terminal 有 `working directory`、`name`；指令 `select tab`、`activate window`、`focus`；**無 tty 屬性**。
- Apple Terminal：現有 `~/.claude/focus-terminal-tab.sh` 以 tty 比對分頁。
- `iconutil`、`sips` 在 `/usr/bin`，icon 可由程式碼渲染 PNG 再組 `.icns`。
- Coucou 已裝在 `/Applications/Coucou.app`（0.5.3），未裝 hooks，`settings.json` 未被動過（備份 `~/.claude-toolkit/backups/settings.json.1793168972.pre-coucou`）。

## 可借用的既有資產

| 來源 | 內容 | 怎麼用 |
|---|---|---|
| `~/.claude/statusline.sh` | 解析 statusLine JSON、寫 session 對應表與 usage.json | 保留不動；cubi 的 statusline relay 先轉發 JSON 給 app，再 exec 它（同 Coucou 串接法） |
| `~/.claude/focus-terminal-tab.sh`、`claude-notify.sh` | Apple Terminal 分頁聚焦（tty）、terminal-notifier | 邏輯搬進 Swift（NSAppleScript），腳本留著當 fallback |
| `~/.claude-toolkit/panel/Panel.swift`、`index.html` | WKWebView 面板 + cctl 橋接白名單 | 整段搬進 cubi 的 Panel module |
| `~/.claude-toolkit/bin/cctl --json` | 面板資料來源 | 不動 |
| Coucou `ClaudeSettingsFile.swift`（MIT） | settings.json 備份 / diff / stale 檢查 / 原子寫入 | 重寫成自己的，邏輯照抄並註明出處 |
| Coucou `nb-hook.py`（MIT） | hook relay 協定：stdin → unix socket → 等回覆 → stdout `hookSpecificOutput` | 協定照抄，程式自己寫 |

## Claude Code 協定事實（官方文件，2026-10-28 查）

來源：https://code.claude.com/docs/en/hooks.md、/statusline.md、/permissions.md。文件未標 2.1.312 的差異，**Phase 0 要先用 debug hook 把真實 payload 錄下來當權威**。

- 共通欄位：`session_id`、`transcript_path`、`cwd`、`hook_event_name`、`permission_mode`、`prompt_id`、`agent_id/agent_type`（子代理）。**沒有 session 名稱、沒有 tty。**
- PermissionRequest：輸入 `tool_name`、`tool_input`、`permission_suggestions[]`；輸出 `{"hookSpecificOutput":{"hookEventName":"PermissionRequest","decision":{"behavior":"allow"|"deny","updatedPermissions":[...],"message":"..."}}}`；stdout 空 + exit 0 = 不決定，交回終端。Always = 把 `permission_suggestions` 原樣放進 `updatedPermissions`。預設 timeout 600s，Coucou 用 120s。
- PreToolUse matcher `AskUserQuestion`：輸出 `permissionDecision:"allow"` + `updatedInput:{questions, answers:{"<question>":"<label>"}}`，多選以逗號串接。
- Notification：`message`、`title`、`notification_type`（`permission_prompt`、`idle_prompt`、`agent_needs_input`、`agent_completed`…）。
- Stop：`last_assistant_message`、`stop_hook_active`。SessionStart matcher `startup|resume|clear|compact|fork`。SessionEnd 預算 1.5 秒。
- Status line stdin：`session_id`、`session_name`（`/rename` 才有）、`cwd`、`workspace.*`、`model.*`、`cost.*`、`context_window.used_percentage`、`rate_limits.five_hour|seven_day.{used_percentage,resets_at}`。事件觸發 + 300ms debounce，可設 `refreshInterval`。
- settings.json：同一事件可多個 group，`timeout` 單位秒；hook command 路徑**不要有空白**（裝在 `~/.cubi/bin/`，避開引號問題）。
- 終端識別：relay 以 `TERM_PROGRAM`、`__CFBundleIdentifier` 環境變數與祖先程序 tty（同 `statusline.sh` 的 `find_claude_tty`）補進 payload（`cubi_term`、`cubi_tty`、`cubi_bundle_id`）。

## 架構

```
Claude Code ──hook stdin──▶ cubi-hook (relay) ──unix socket──▶ Cubi.app
                ◀─stdout JSON─┘            ◀──reply line───┘   │
                                                                ├─ HookServer（收事件、同 UID 檢查、pending 審批）
~/.claude/statusline.sh ◀── exec ── cubi-hook --statusline      ├─ SessionStore（session → 狀態、顏色、cwd、tty、term）
                                                                ├─ NotchWindow（NSPanel 置頂、輪詢滑鼠、展開/收合）
                                                                ├─ CubiBot（Canvas 角色，每 session 一隻）
                                                                ├─ Cards（Approval / Question / Diff / Usage）
                                                                ├─ Plugins（AgentPlugin 協定；內建 ClaudeCodePlugin）
                                                                ├─ Focus（Terminal.app tty / Ghostty cwd / VS Code）
                                                                └─ Panel（WKWebView 載現有 index.html，橋接 cctl）
```

**SwiftPM 三個 target**（細節依 Plan agent 結論，見「打包與 relay 決策」）：

| Target | 類型 | 內容 | 可測 |
|---|---|---|---|
| `CubiKit` | library | 事件模型、canonical event、session 狀態機、hook JSON 解析、`SettingsFile`（備份/diff/原子寫入）、plugin manifest、顏色雜湊 | `swift test` 純邏輯 |
| `cubi` | executable | AppKit/SwiftUI app 本體 | 手動 + `--render-icon`、`--demo` 模式 |
| `cubi-hook` | executable | relay：stdin → socket → stdout | shell 測試：喂假 payload |

### 事件流（canonical events，plugin 把各 agent 的事件對到這裡）

`sessionStart`、`prompt(text)`、`toolStart(name, input)`、`toolEnd(name, ok, summary, diff?)`、`permissionRequest(tool, input, suggestions) → reply`、`question(questions) → reply`、`notification(type, message)`、`stop(lastMessage)`、`sessionEnd`、`statusline(contextPct, rate5, rate7, resets, sessionName, model)`。

### Session 身分與顏色

- key = `session_id`。名稱：statusline 的 `session_name`，沒有就 `cwd` basename，再沒有就 id 前 8 碼（同 `notify-hook.sh` 的三層 fallback）。
- 顏色：`session_id` 穩定雜湊（FNV-1a，**不用** Swift `hashValue`，它每次啟動換種子）→ 12 色盤取一格；同色碰撞時取下一格。
- terminal：relay 附上的 `cubi_term`（`TERM_PROGRAM`）、`cubi_bundle_id`、`cubi_tty`。
- session 結束：`sessionEnd` 或 `stop` 後 N 分鐘無事件 → 淡出；`SessionStart source=resume` 回來。

### UI 行為（借 Coucou 做法，已讀 `IslandWindowController.swift` 等）

| 項目 | 做法 |
|---|---|
| 視窗 | `NSPanel`：`[.borderless, .nonactivatingPanel]`、clear、`level = mainMenu + 3`、`collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]`、覆寫 `constrainFrameRect` 回傳原值、`canBecomeKey` 只在輸入時 |
| 瀏海量測 | `hasNotch = safeAreaInsets.top > 0`；寬 = `frame.width − auxiliaryTopLeftArea.width − auxiliaryTopRightArea.width`（fallback 184）；高 = `safeAreaInsets.top`；無瀏海螢幕 = 80×24 小條置頂中央 |
| 多螢幕 | 預設瀏海螢幕；監聽 `didChangeScreenParametersNotification` 重算；設定可改「跟隨滑鼠」 |
| 滑鼠 | 面板預設 `ignoresMouseEvents = true`；主 RunLoop Timer 輪詢 `NSEvent.mouseLocation`（遠 8Hz、近 20Hz、展開 60Hz），命中 island 矩形才接收事件；螢幕鎖定／睡眠停輪詢 |
| 狀態 | `hidden`（只有瀏海）→ `compact`（瀏海 + 160pt，機器人們並排）→ `expanded`（640 寬、160～240 高，卡片）；hover 開 compact、點開 expanded、15s 無操作收回；有 pending 審批時**不收** |
| 動畫 | 只動 SwiftUI `IslandShape`（animatable 寬高圓角），視窗 frame 不動；開 `spring(response 0.5, damping 0.72)`、關 `timingCurve(0.45,0,0.2,1, 0.34s)` |
| 卡片 | Approval：工具名、目標（指令／檔案／URL）、Allow / Deny / Always；Question：每題選項按鈕（multiSelect 用勾選）；Diff：+N −M 與逐行；Usage：5h / 7d 進度條與 reset 時間（台灣時間） |
| 多 session | compact 一排小機器人（每隻 ≤ 20pt，各自顏色）；expanded 左側清單、右側卡片；當前審批的那隻跳動 |
| 聚焦 | 點機器人 → 依 `cubi_term`：Terminal.app 用 tty 找分頁（搬 `focus-terminal-tab.sh` 邏輯進 `NSAppleScript`）；Ghostty 用 AppleScript 找 `working directory == cwd` 的 terminal，`activate window` + `select tab`，找不到退回標題包含 session 名；VS Code 只 activate app；設定可加自訂 terminal（bundle id + 策略） |
| 通知 | 保留你現有 Notification hook 不動；cubi 自己對 `permission_prompt`／`agent_needs_input` 也能發系統通知（`UNUserNotificationCenter`），設定可關其一 |
| Menubar | `NSStatusItem` 保留但**不依賴**：實測（2026-10-28）Jade 的 menubar 已滿，macOS 把溢出項目藏在瀏海後面（新 item 被放在 x=664，瀏海 663–848，occlusion 不可見）。所以選單改成島上右鍵、再點 app 圖示會展開島；用量數字改顯示在島的 compact 右翼／expanded 卡片，不放 menubar |
| 省電 | `TimelineView(.animation(paused: hidden))`；收合時小機器人暫停；無 session 時輪詢降到 8Hz |

### 角色 Cubi 規格（程式碼畫，`Canvas` + `TimelineView`）

- 本體：導角方塊，`RoundedRectangle` 圓角 ≈ 寬 × 0.28，底色 = session 色；上層淡漸層 + 內側陰影一圈 + 左上高光；高度隨瀏海（≤ `notchH − 6`）。
- 眼睛：兩個圓角矩形，依狀態變形；眨眼 70ms 閉／130ms 開，間隔 2.2 + rand(0…3.2) s；眼珠跟滑鼠（`tanh(dx/260)`）。
- 固定 `dt = 0.05` 每幀步進（Coucou 實測真實 dt 會抖）。
- 狀態表：

| 狀態 | 觸發 | 眼 | 其他 |
|---|---|---|---|
| idle | sessionStart / stop 後 | 橫長圓角矩形 | 偶爾眨眼 |
| thinking | prompt 送出 | 看右上 | 頭頂三點閃 |
| working | toolStart | 普通 | 身體輕微上下、腳下進度小點 |
| waiting | permissionRequest / question | 睜大 | 「!」或「?」徽章，跳動，直到回覆 |
| error | PostToolUseFailure / StopFailure | 扁平 | 左右抖一次 |
| sleeping | 10 分鐘無事件 | 閉眼弧線 | 呼吸縮放 `1 + sin(t·1.8)·0.035`、Zzz |
| happy | 點臉／stop 後 1.5 秒 | 彎月 | 小跳 + 兩顆火花 |
| **tired** | `context_window.used_percentage ≥ 80`；≥ 90 更累 | 半閉、下垂 | 額頭汗滴、顏色降飽和；≥ 90 加紅色邊框脈動。點它顯示「Context 92%，建議 /clear」 |

- 音效：先用 macOS 內建 `/System/Library/Sounds/*.aiff`（例如 Tink＝審批出現、Pop＝完成、Basso＝錯誤），`NSSound` 播，音量 0.15；設定可關。不做素材。
- 圖示：app 自己 `cubi --render-icon out.png`（`ImageRenderer` 畫 1024px 的 Cubi），`scripts/make-icns.sh` 用 `sips` + `iconutil` 組 `.icns`。menubar 用 template 版（單色）。

### 打包與簽章（Plan agent 實測後的決策）

| 決策 | 做法 | 為什麼 |
|---|---|---|
| **簽章用自簽憑證，不用 ad-hoc** | 一次性在 Keychain Access 建 Code Signing 憑證 `cubi-dev`（Certificate Assistant → Create a Certificate → 類型 Code Signing）；`make cert` 用 `security find-identity -p codesigning`（不帶 `-v`）偵測；`codesign --force --sign cubi-dev --identifier cc.dotdot.cubi`，先簽 `cubi-hook` 再簽 app，不用 `--deep` | 實測：這台 0 個簽章身分，現有 `ClaudeToolkit.app` 的 designated requirement 是 `cdhash`，重編就變，TCC 存的 Automation 授權對不上會**靜默失敗 -1719**（設定裡還顯示開）。自簽後 DR 變成 `identifier + certificate leaf`，重編不掉授權。Keychain ACL 同理 |
| 進入點 | `Sources/cubi/main.swift` AppKit top-level（`NSApplication.shared` + `AppDelegate` + `.accessory`），SwiftUI 只經 `NSHostingView` 進 `NSPanel`，**不用** SwiftUI `App`/Scene | 避開 `@main` 與 main.swift 衝突、無 Scene 的 adaptor 怪異、`WindowGroup` 偷開空窗 |
| Info.plist | 手寫 `Packaging/Info.plist`：`LSUIElement`、`CFBundleIdentifier`、`NSAppleEventsUsageDescription`、`LSMinimumSystemVersion`、`NSHighResolutionCapable`；`bundle.sh` 用 `PlistBuddy` 塞 `CFBundleVersion=$(git rev-list --count HEAD)` | TCC 只看 usage string、bundle id、csreq，沒 Xcode 沒差 |
| 資源 | `Sources/cubi/Resources/`（index.html、fixtures）以 `resources: [.copy("Resources")]` 宣告；`bundle.sh` 把 `.build/release/cubi_cubi.bundle` 複製進 `Contents/Resources/` | `Bundle.module` 先查 `Bundle.main.resourceURL`，`swift run` 與 .app 兩邊都能用 |
| 語言模式 | Swift 6；`CubiKit` 全值型別；app 層 `@MainActor`；socket server `final class HookServer: @unchecked Sendable` + `DispatchSourceRead`。卡住時只對 `cubi` target 退 `.swiftLanguageMode(.v5)` | 新碼不欠債 |
| 部署目標 | `.macOS(.v15)` | 用到的 API 都 ≤ 15；同事機器不一定是 26；編譯器幫擋 26-only API |
| Makefile | `cert` / `build` / `test` / `bundle` / `install`（→ `~/Applications/Cubi.app`）/ `run` / `icon` | icon 步驟放最後、失敗不中斷 |
| 首次執行後 | `tccutil reset AppleEvents cc.dotdot.cubi` 一次（若之前用 ad-hoc 試過） | 清掉舊 csreq |

### Hook relay（`cubi-hook`）

- **Swift，只 import Darwin，不連 Foundation、不解析 JSON**：讀整段 stdin → 包信封 → 送 socket。冷啟動個位數 ms（python3 實測 100 ms，statusline 串流時每秒多次）。JSON 字串跳脫自己寫 30 行。
- 安裝位置：app 把 `Contents/MacOS/cubi-hook` 複製到 `~/Library/Application Support/cubi/bin/cubi-hook`，settings.json 指這裡；app 啟動時比 hash 自動更新。路徑無空白。
- 終端身分：`TERM_PROGRAM`、`__CFBundleIdentifier`、`TERM_SESSION_ID` 環境變數；tty 用 `proc_pidinfo(PROC_PIDTBSDINFO)` 取 `e_tdev` → `devname()`，沿 `pbi_ppid` 往上最多 8 層，零 fork。
- Socket：`~/Library/Application Support/cubi/cubi.sock`，目錄 0700、socket 0600，app 端 `getpeereid` 同 UID 才收。
- 協定：

```
→ {"v":1,"agent":"claude-code","event":"PermissionRequest","pid":123,
   "client":{"term_program":"ghostty","bundle_id":"com.mitchellh.ghostty","tty":"/dev/ttys004","term_session_id":"…"},
   "payload":{…stdin 原樣…}}\n
← {"v":1,"stdout":{…hookSpecificOutput…},"exit":0}\n   或直接 EOF（= 不決定）
```

- 三類行為：**blocking**（`PermissionRequest`、`PreToolUse --tool AskUserQuestion`）等回覆或 EOF，自設 deadline 115 s（< hook `timeout:120`，讓 Claude Code 看到乾淨空輸出）；**fire-and-forget**（其餘）寫完 `shutdown(SHUT_WR)` 即退；**statusline**（`cubi-hook statusline --then '<原命令>'`）送完後 `execvp` 原命令並餵回 stdin，exit code 透傳。原命令存 `agents/claude-code.json` 的 `previousStatusLine`，解除安裝還原，安裝前偵測已包過不重包。
- connect 非阻塞 + poll 300 ms；`ENOENT`/`ECONNREFUSED` → exit 0 空輸出。
- 一條連線 = 一個待決請求，**以 fd 為鍵**（不用 session_id），與 Coucou 同。

### Plugin 介面（第 8 項）

v1 只做 Swift protocol + `ClaudeCodePlugin`；protocol 設計成「回傳資料、不回呼」，讓之後 `ManifestPlugin: AgentPlugin` 能純靠 JSON 實作。manifest 的 `install.mode` 只支援 `json-hooks` 與 `manual`（app 顯示說明讓使用者自己貼），因為 Codex 的 `config.toml` merge 無法宣告化。取捨：加 Codex 仍要重編；換來安裝路徑可測、可備份、可 diff。

```swift
public protocol AgentPlugin: Sendable {
  static var id: AgentID { get }                 // "claude-code"
  var displayName: String { get }
  var accentColor: RGB { get }
  var capabilities: AgentCapabilities { get }    // [.approvals, .questions, .statusline]
  var secrets: [SecretSpec] { get }              // key, label, required → Keychain（login keychain）
  var installer: any HookInstaller { get }       // plan() -> InstallPlan{file, backup, diff}; apply(); status(); uninstall()
  func decode(_ e: HookEnvelope) throws -> CanonicalEvent?
  func encodeReply(_ r: CanonicalReply, for e: HookEnvelope) throws -> HookReply
  func isBlocking(nativeEvent: String, tool: String?) -> Bool
}
enum CanonicalReply { allow(updatedInput:), deny(message:), answers([String: String]), passthrough }
```

Manifest 草案（`plugins/<id>/manifest.json`，目錄 0700）：`id / name / color / capabilities / secrets[] / install{mode,file,key,entries[]} / events{native:{canonical,map(JSON path),reply}} / adapter{command,timeout}`。adapter 只給 stdin/stdout、清空環境變數、2 s timeout，啟用時 UI 顯示路徑與 hash；不做沙箱（與 hook 同等信任）。每個 plugin 預設關；關 = 不裝 hooks、不顯示、不載 adapter。

### 已知陷阱與對策

| 陷阱 | 對策 |
|---|---|
| Claude Code 在 session 啟動時快照 hooks，中途改 settings.json 不生效 | 安裝後 UI 顯示「重啟 Claude Code」橫幅；N 分鐘沒收到 `SessionStart` 再提示 |
| 雙重提示競態：終端與瀏海同時問，使用者在終端答了 → hook 被取消 → relay EOF | app 用 `DispatchSourceRead` 偵測 fd 關閉收卡（標「已在終端處理」）；點擊只套用在同一個 fd，絕不落到下一個請求 |
| app 當機 / relay 超時 | 皆退化成終端自己問；守住 relay 的 115 s deadline；`SessionEnd` 預算 1.5 s 必須 fire-and-forget |
| settings.json 被 Claude Code 自己改（Always 寫 localSettings） | CAS：讀原 bytes → 算 → 寫前比對未變；備份 `~/.claude/backups/cubi/settings.json.<ts>.bak`；UI 看 diff 才寫；只**追加**自己的條目，不動 `notify-hook.sh`、`zh-reply-guard.py` |
| 多 session | 單一 listen fd、連線上限 64、非阻塞 5 s 讀逾時、待決請求排 queue（卡片顯示 head + 「n 件等待」） |
| 單一實例 | 啟動先 connect 既有 socket，成功就退出；失敗才 unlink 再 bind |
| AppleScript 卡 UI | 用 `Process("/usr/bin/osascript")` + 5 s timeout，不用 `NSAppleScript`（main thread） |
| Payload 漂移 | 設定「debug capture」寫 `capture/<date>.jsonl`（0600、20 MB 上限）；decoder 遇未知事件記錄不丟錯；fixtures 放 `Tests/CubiKitTests/Fixtures/claude-2.1.312/`；安裝時記 `claude --version`，變了提示 |
| Keychain | 無 Developer ID 只能用 login keychain；自簽憑證讓 ACL 穩定 |

### 需要你親手做的（一次性）

1. Phase 1：Keychain Access 建 `cubi-dev` Code Signing 憑證（我給逐步說明）。
2. 首次執行：macOS 會問 Automation（控制 Terminal / Ghostty）、通知權限，按允許。
3. Phase 6：Install hooks 時看 diff 按確認。

## 分期

| Phase | 交付 | 驗收 |
|---|---|---|
| 0 偵察 | repo 初始化、SwiftPM 骨架、`cubi-hook --capture` 把 2.1.312 真實 hook payload 原樣錄到 `~/Library/Application Support/cubi/capture/`，跑一輪 session 拿到每種事件的樣本 | 每種事件至少一份樣本，欄位名寫進 `docs/protocol.md` |
| 1 骨架 | NSPanel 置頂瀏海視窗、hover 展開收合、一隻 idle Cubi 會眨眼、menubar 圖示、.app 打包、`make cert` + 自簽、單一實例、開機啟動開關 | 看得到、hover 會開、重編後 Automation 授權不掉、CPU 收合時 ≈ 0 |
| 2 監看 | HookServer + relay 全事件、SessionStore、多 session 多隻多色、狀態表除 tired 外全部、ticker、統一 Notification 通知 | 同時開兩個 Claude Code，各自一隻、顏色不同、狀態會變 |
| 3 審批 | PermissionRequest 卡片 Allow/Deny/Always、AskUserQuestion 卡片、pending 時不收合、音效 | 終端的詢問改在瀏海按，Always 寫進 Claude Code 規則，hook 逾時與 app 關閉時終端自己問 |
| 4 用量與疲憊 | statusline relay 串接現有 `statusline.sh`、Usage 卡片、menubar 用量、tired 狀態 | `statusline.sh` 輸出不變；用量數字與 `usage.json` 一致；context ≥ 80 時表情變 |
| 5 聚焦與 diff | Terminal.app / Ghostty / VS Code 聚焦、自訂 terminal 設定、Diff 卡片 | 點 Ghostty session 的機器人會跳到正確分頁 |
| 6 面板與安裝器 | WKWebView 面板搬入、settings.json 安裝器（備份/diff/確認）、設定頁、`cctl menubar` 退役 | 安裝 hooks 後原有 Notification／Stop hook 與 statusLine 仍在，diff 只多 cubi 條目 |
| 7 Plugin 化 | `AgentPlugin` 協定定稿、`ClaudeCodePlugin` 收斂到協定後、設定頁 plugin 開關 + Keychain secrets、manifest schema 文件與 `json-hooks` 模式載入器（不含 adapter 執行） | 關掉 Claude Code plugin → 不裝 hooks、不顯示；用一份假 manifest 能載入並顯示第二顆 pill（不接真 agent） |
| 8 發佈 | README（建置步驟、權限說明）、`make install`、GitHub push | 同事照 README 從原始碼建得起來 |

每個 Phase 結束：`swift test`、手動驗收、commit（訊息我擬、你核准）。Phase 1 完成即可先用。

### Cubi 完成後要退役的舊工具（Jade 2026-10-29 指示）

| 舊工具 | 由誰取代 | 退役時機 |
|---|---|---|
| `~/.claude/notify-hook.sh` + `claude-notify.sh` + `focus-terminal-tab.sh`（Notification hook 桌面通知、點擊聚焦分頁） | Cubi 系統通知（右鍵「系統通知」）+ Phase 5 聚焦 | Phase 6 安裝器可選「移除舊 Notification hook」 |
| `ClaudeToolkit.app` menubar 用量（`cctl menubar`） | 島的右翼用量與 expanded 用量列 | Phase 6（面板併入後 `cctl menubar stop`） |
| `statusline.sh` 裡的 context / 5h / 7d 門檻通知 | tired 表情、用量列顏色 | Phase 6，改 statusline.sh 時只留顯示與 usage.json |
| `~/.claude-toolkit/panel/`（WKWebView 管理面板） | 併入 Cubi（Phase 6） | Phase 6 |

保留：`statusline.sh` 的狀態列顯示本身、`cctl` CLI、`zh-reply-guard.py`。

## 驗證

- 單元：`CubiKit` 的事件解析（用 Phase 0 錄到的真實 payload 當 fixture）、狀態機轉換、顏色雜湊穩定、`SettingsFile` 的備份／stale／原子寫入（在 temp 目錄）。
- Relay：`echo '<fixture>' | cubi-hook` 在 app 未開時 300ms 內退出、stdout 空、exit 0；app 開時 PermissionRequest 等到按鈕回覆後印 `hookSpecificOutput`。
- 整合：真的開 Claude Code（可用 `claude -p` 跑簡單指令），看機器人狀態；跑一個需要權限的 Bash 指令，在瀏海按 Deny，終端收到拒絕。
- 效能：`top -pid` 收合時 ≤ 1%；展開動畫時不超過 30%。
- 安全：socket 權限 0600；用另一個使用者或假 UID 無法連；`settings.json` 每次寫入前有 `.bak-<時間>`。
- 回歸：裝完後 `statusline.sh` 的輸出與 `usage.json`、`/tmp/claude-sessions/` 照常更新。

## 不做（這一版）

多 agent 實作（只做介面）、手機端、聊天、聽寫、服務 pill、Mochi 式衣櫃、多國語言（UI 繁中＋英文字串常數，不做 localization 機制）。
