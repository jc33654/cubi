# cubi-hook ↔ Cubi.app 協定

版本 `v: 1`。relay（`cubi-hook`）不解析 JSON，只做信封與轉送；所有解析在 `CubiKit`。

## Socket

- 路徑：`~/Library/Application Support/cubi/cubi.sock`（目錄 0700、socket 0600）。
- app 端 `getpeereid` 檢查 euid == getuid，其他 UID 直接關閉。
- relay connect 預算 300 ms；`ENOENT` / `ECONNREFUSED` → exit 0、stdout 空。

## 請求（relay → app，一行 JSON + `\n`）

```json
{"v":1,"agent":"claude-code","event":"PermissionRequest","tool":null,"pid":123,"ppid":122,
 "client":{"term_program":"ghostty","bundle_id":"com.mitchellh.ghostty","term_session_id":null,"tty":"/dev/ttys009"},
 "payload":{ ...hook stdin 原樣（去除換行）... }}
```

| 欄位 | 來源 |
|---|---|
| `agent` | `--agent`，預設 `claude-code` |
| `event` | `--event`，或 `statusline` |
| `tool` | `--tool`（只有 PreToolUse 的 AskUserQuestion matcher 會帶） |
| `client.term_program` | `TERM_PROGRAM` |
| `client.bundle_id` | `__CFBundleIdentifier`（LaunchServices 給的） |
| `client.term_session_id` | `TERM_SESSION_ID`（Terminal.app 才有） |
| `client.tty` | 沿 `pbi_ppid` 往上最多 8 層，第一個有 `e_tdev` 的程序 |
| `payload` | stdin；空 stdin 為 `null` |

## 回覆（app → relay）

- **blocking 事件**（`PermissionRequest`、`PreToolUse` + `AskUserQuestion`）：relay 等一行回覆，**原樣**印到 stdout，exit 0。app 直接送 Claude Code 要的 `hookSpecificOutput` JSON 一行。EOF 無回覆 = 不決定，Claude Code 在終端自己問。relay 自設 deadline 115 s（hook `timeout` 設 120）。
- **其他事件**：relay 寫完 `shutdown(SHUT_WR)` 就退，不等回覆。
- **statusline**：relay 送完信封後以 `/bin/sh -c <--then 之後的字串>` 執行原本的 statusLine 指令，stdin 餵同一份 JSON，stdout 與 exit code 透傳。

## Capture 模式

`--capture` 把信封追加到 `~/Library/Application Support/cubi/capture/<agent>-<event>[-<tool>].jsonl`（0600）。用途：錄真實 payload 當 fixtures（`Tests/CubiKitTests/Fixtures/claude-<version>/`）。

## Claude Code 2.1.312 實錄欄位（2026-10-28，`Tests/CubiKitTests/Fixtures/claude-2.1.312/`）

共通：`session_id`、`transcript_path`、`cwd`、`hook_event_name`、`scratchpad_dir`；第一個 prompt 之後多 `prompt_id`、`permission_mode`（實錄值 `auto`、`default`）、`effort.level`。**沒有 session 名稱、沒有 tty。**

| 事件 | 專屬欄位 | 備註 |
|---|---|---|
| SessionStart | `source`（`startup`）、`model` | 沒有 `permission_mode` |
| UserPromptSubmit | `prompt` | |
| PreToolUse | `tool_name`、`tool_input`、`tool_use_id` | AskUserQuestion 的 `tool_input.questions[]{question, header, options[]{label, description}, multiSelect}` |
| PostToolUse | 同上 + `tool_response`（Bash：`{stdout, stderr, interrupted, ...}`）、`duration_ms` | |
| PermissionRequest | `tool_name`、`tool_input`、`permission_suggestions[]` | 實錄：`[{"type":"addRules","rules":[{"toolName":"Bash","ruleContent":"curl -s https://example.com"}],"behavior":"allow","destination":"localSettings"}]`。**AskUserQuestion 也會走 PermissionRequest**（`permission_suggestions: null`）：當 PreToolUse 沒給答案時出現；app 對它回「不決定」 |
| Notification | `notification_type`、`message`、`title`（可為 null） | 實錄 `idle_prompt`「Claude is waiting for your input」、`permission_prompt`「Claude needs your permission」 |
| Stop | `last_assistant_message`、`stop_hook_active`、`background_tasks[]`、`session_crons[]` | |
| SubagentStart | `agent_id`、`agent_type`（如 `Explore`） | 沒有 `permission_mode` |
| SubagentStop | `agent_id`、`agent_type`、`agent_transcript_path`、`last_assistant_message`、`background_tasks[]{id,type,status,description,agent_type}` | |
| SessionEnd | `reason`（`prompt_input_exit`） | 預算 1.5 s |
| PostToolUseFailure、StopFailure | 未錄到 | 解析器視為可選 |

## 已驗證（2026-10-28，Claude Code 2.1.312 的 relay 端）

- app 不在：fire-and-forget 與 blocking 都在 ~12 ms 內退出，exit 0，stdout 空。
- 假 app（python unix socket）：fire-and-forget 送達；blocking 收到回覆行並原樣印出，約 47 ms。
- statusline 串接：stdout 透傳、exit code 透傳（`--then 'exit 3'` → 3）、與真實 `~/.claude/statusline.sh` 串接輸出正常。
- JSON 跳脫：引號、換行、中文、控制字元 round-trip 正確。
- `client.tty` 正確指到執行 Claude Code 的 Ghostty 分頁 tty。

## Plugin manifest（`~/Library/Application Support/cubi/plugins/<id>/manifest.json`）

兩種：沒有 `kind`（或 `"kind": "agent"`）是 agent plugin，`"kind": "tool"` 是工具插件（下一節）。兩種共用一個 id 命名空間，重複的那個目錄會被拒載。

### Agent plugin

範例：`docs/plugins/example-agent/manifest.json`。載入規則在 `Sources/CubiKit/ManifestPlugin.swift`。

| 欄位 | 必填 | 說明 |
|---|---|---|
| `schema` | | 目前 `1` |
| `id` | ✔ | `[a-z0-9-]`，最多 24 字元，同時是 relay 的 `--agent` 值與 socket 信封的 `agent` |
| `name` | ✔ | 設定頁顯示名 |
| `color` | | `#RRGGBB`，沒給用灰 |
| `capabilities` | | 只有 `statusline` 有作用。`approvals`、`questions` 會被忽略：manifest 沒有回覆模板，這種 plugin 的審批與問題不會上島（見下方行為） |
| `secrets[]` | | `{key, label, required}`；值存登入鑰匙圈，不進 manifest |
| `install.mode` | | `json-hooks` 或 `manual`（預設）。`manual` 時 `install.instructions` 顯示給使用者自己貼 |
| `install.file` | json-hooks 必填 | 要寫的 JSON 檔，可用 `~`。格式比照 Claude Code：`hooks.<event>[] = { hooks: [{type, command, timeout}] }` |
| `install.entries[]` | json-hooks 必填 | `{event, command, timeout}`。**`command` 必須含 `cubi-hook --agent <id> `**（尾端空白），安裝狀態與解除都靠這個 tag 辨識自己的條目；沒有就拒載 |
| `events.<native>` | | 原生事件名 → `{canonical, map}` |
| `events.<native>.canonical` | ✔ | `sessionStart`、`prompt`、`toolStart`、`toolEnd`、`permissionRequest`、`question`、`notification`、`stop`、`sessionEnd` |
| `events.<native>.map` | | canonical 欄位 → JSON path（只支援 `$.a.b` 物件走訪，沒有陣列索引）。沒對映的欄位用 Claude Code 的預設路徑 |

`map` 可用的欄位（括號是預設路徑）：

| 欄位 | 用於 | 預設 |
|---|---|---|
| `session` | 全部，必要 | `$.session_id` |
| `cwd`、`transcript` | 全部 | `$.cwd`、`$.transcript_path` |
| `tool`、`input`、`toolUseID` | toolStart、toolEnd、permissionRequest、question | `$.tool_name`、`$.tool_input`、`$.tool_use_id` |
| `ok`、`response` | toolEnd | `$.ok`、`$.tool_response` |
| `source` | sessionStart | `$.source` |
| `prompt` | prompt | `$.prompt` |
| `type`、`message` | notification | `$.notification_type`、`$.message` |
| `message` | stop | `$.last_assistant_message` |
| `reason` | sessionEnd | `$.reason` |

行為：

- 未知 `agent` 的信封直接丟棄；plugin 關閉時不裝 hooks、不顯示、不解碼。
- 解除安裝只刪 `command` 含自己 tag 的 group，其他 plugin 與使用者自己的 hooks 不動。
- blocking 事件（`permissionRequest`、`question`）decode 出來後，plugin 沒有對應的 `approvals` / `questions` 能力時 app 不開卡片、不出聲，直接關連線讓 agent 用自己的提示；機器人當成 `toolStart` 顯示 working。manifest plugin 一律如此。

### 工具插件（`"kind": "tool"`）

一個 HTML 面板加一張它的 JavaScript 可以執行的指令表。範例：`docs/plugins/example-tool/`（manifest 加一頁 HTML）。載入與驗證在 `Sources/CubiKit/ToolPlugin.swift`，執行在 `Sources/cubi/Plugins/ToolPanel.swift`。工具插件預設開啟（只有使用者打開面板、按了東西才會執行）；選單與設定頁「插件 → 工具」各有一個入口。

| 欄位 | 必填 | 說明 |
|---|---|---|
| `kind` | ✔ | `tool` |
| `id`、`name` | ✔ | 同 agent：`[a-z0-9-]`，最多 24 字元；`name` 是視窗標題與選單文字 |
| `panel.file` | ✔ | HTML 檔：相對插件目錄，或 `~`／絕對路徑。每次開窗重讀。`baseURL` 為 nil：沒有 file:// 基底、origin 是 null；外部資源（script、img、fetch）**不擋**，面板 HTML 跟 manifest 一樣是使用者自己放的、一樣信任 |
| `panel.width`、`panel.height` | | 視窗大小，預設 900×640 |
| `panel.bridge` | | JS 用的 handler 名，預設 `cubi`；既有面板寫死別的名字就在這裡宣告，不用改面板 |
| `commands.<action>.run` | ✔ | argv。第一個是執行檔，必須是絕對路徑（可用 `~`）；**不經 shell**。`$1`…`$n` 代入呼叫端的第 n 個參數 |
| `commands.<action>.args[]` | | 每個參數的型別，數量必須跟呼叫端送的一樣：`"name"`（`[A-Za-z0-9._-]{1,64}`，不能是 `.`／`..`：檔名／資產名，走不出目錄）、`"value"`（可印字元 ≤512，不能以 `-` 開頭，所以變不成選項）、`{"enum": […]}`、`"text"`（≤256 KB，只能走 stdin） |
| `commands.<action>.stdin` | | 1-based：第 n 個參數餵 stdin 而不是 argv（長內容用） |
| `commands.<action>.reveal` | | `true`：把 stdout（去頭尾空白）當路徑在 Finder 選取，回 `{ok, out: 路徑}` |

JS 端：

```js
const bridge = window.webkit?.messageHandlers?.cubi;          // 或 manifest 的 panel.bridge
const r = await bridge.postMessage({ action: "skill.on", args: ["my-skill"] });   // {ok, out, err}
await bridge.postMessage({ action: "config.set", name: "k", value: "v" });        // 舊形狀：name/value → args
const picked = await bridge.postMessage({ action: "pick.file", args: [] });      // 內建：{ok, path, cancelled?}
```

規則：

- action 不在表裡、參數數量或型別不符 → 不執行，JS 收到 reject（錯誤訊息是中文的原因）；每次執行與拒絕都寫 `~/Library/Logs/cubi.log`。
- `pick.file`／`pick.dir` 是內建的原生選擇器，不用宣告，也是保留字（manifest 裡定義會被拒載）。
- 設定頁關掉工具後，已開著的面板送來的請求也會被拒。
- manifest 是使用者自己放進 `plugins/` 的，跟 agent manifest 一樣信任它；安全邊界在「面板的 JS 只能叫到表裡的指令、參數過型別檢查、不經 shell」。
- 測試用：`cubi --tool-run <id> <action> [args…]` 用同一條路徑執行並印 `{ok, out, err}`。
