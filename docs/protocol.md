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
