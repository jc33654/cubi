# 進階操作

README 講怎麼用；這裡是插件規格、命令列、行事曆規則，給要自己接東西的人。relay 的 socket 協定在 [protocol.md](protocol.md)。

## 插件

都放在 `~/Library/Application Support/cubi/plugins/<id>/manifest.json`。設定頁「插件」有「重新載入」與「開啟 plugins 目錄」。兩種：沒有 `kind`（或 `"kind": "agent"`）是 agent plugin，`"kind": "tool"` 是工具插件。兩種共用一個 id 命名空間，重複的那個目錄會被拒載，原因列在設定頁。

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

一個 HTML 面板加一張它的 JavaScript 可以執行的指令表，選填再掛兩個 hook：`session`（session 資訊窗的一塊）與 `tick`（定時執行、可請 app 寫行事曆）。範例：`docs/plugins/example-tool/`（最小）、`docs/plugins/sprint/`（完整）。載入與驗證在 `Sources/CubiKit/ToolPlugin.swift`，執行在 `Sources/cubi/Plugins/`。工具插件預設開啟。

| 欄位 | 必填 | 說明 |
|---|---|---|
| `kind` | ✔ | `tool` |
| `id`、`name` | ✔ | 同 agent：`[a-z0-9-]`，最多 24 字元；`name` 是視窗標題、選單文字、資訊窗區塊標題 |
| `panel.file` | ✔ | HTML 檔：相對插件目錄，或 `~`／絕對路徑。每次開窗重讀。`baseURL` 為 nil：沒有 file:// 基底、origin 是 null；外部資源（script、img、fetch）**不擋**，面板 HTML 跟 manifest 一樣是使用者自己放的、一樣信任 |
| `panel.width`、`panel.height` | | 視窗大小，預設 900×640 |
| `panel.bridge` | | JS 用的 handler 名，預設 `cubi`；既有面板寫死別的名字就在這裡宣告，不用改面板 |
| `commands.<action>.run` | ✔ | argv，**不經 shell**。第一格是執行檔：絕對路徑、`~`、`$plugin/…` 或相對插件目錄的路徑（一定要含 `/`，只寫名字不會去 PATH 找）。任何一格可用 `$plugin` 代表插件目錄（只認整格 `$plugin` 或 `$plugin/…` 開頭）；`$1`…`$n` 代入呼叫端的第 n 個參數。命令的工作目錄就是插件目錄 |
| `commands.<action>.args[]` | | 每個參數的型別，數量必須跟呼叫端送的一樣：`"name"`（`[A-Za-z0-9._-]{1,64}`，不能是 `.`／`..`：檔名／資產名，走不出目錄）、`"value"`（可印字元 ≤512，不能以 `-` 開頭，所以變不成選項）、`{"enum": […]}`、`"text"`（≤256 KB，只能走 stdin） |
| `commands.<action>.stdin` | | 1-based 整數：第 n 個參數餵 stdin 而不是 argv（長內容用） |
| `commands.<action>.reveal` | | `true`：把 stdout（去頭尾空白）當路徑在 Finder 選取，回 `{ok, out: 路徑}` |
| `session.info` | | 命令名。資訊窗選到 session 時執行，之後每 `session.refresh` 秒（整數，≥10，預設 60）一次，島收起就停。見下方「session hook」 |
| `tick.action` | | 命令名。每 `tick.every` 秒（整數，≥30，預設 60）執行一次，不管島開不開。見下方「tick hook」 |

被 `session.info`／`tick.action` 指到的命令（以及資訊窗按鈕要叫的命令）叫 **hook 命令**，形狀固定：`"args": ["text"], "stdin": 1`，不能 `reveal`。app 把自己組的 JSON 餵進 stdin，讀 stdout 的 JSON。不符就整個 manifest 拒載。hook 命令有 20 秒上限，到期 SIGKILL；**不要留背景子行程**（孫行程握著 stdout 會讓 app 一直等到它結束）。面板與 `--tool-run` 叫的命令沒有時間上限。

JS 端（面板）：

```js
const bridge = window.webkit?.messageHandlers?.cubi;          // 或 manifest 的 panel.bridge
const r = await bridge.postMessage({ action: "skill.on", args: ["my-skill"] });   // {ok, out, err}
await bridge.postMessage({ action: "config.set", name: "k", value: "v" });        // 舊形狀：name/value → args
const picked = await bridge.postMessage({ action: "pick.file", args: [] });      // 內建：{ok, path, cancelled?}
// 從資訊窗「開面板」打開時：
window.cubiSession   // {id, name, cwd, projectDirectory, agent, segments}；之後換 session 會收到 "cubisession" 事件
```

規則：

- action 不在表裡、參數數量或型別不符 → 不執行，JS 收到 reject（錯誤訊息是中文的原因）；每次執行與拒絕都寫 `~/Library/Logs/cubi.log`。
- `pick.file`／`pick.dir` 是內建的原生選擇器，不用宣告，也是保留字（manifest 裡定義會被拒載）。
- 面板裡任何離開已載入 HTML 的導頁（連結、`location.href`、表單、meta refresh）一律取消；http(s) 的目標改用系統瀏覽器開。bridge 永遠只給面板自己的頁面用。
- 設定頁關掉工具後，已開著的面板送來的請求也會被拒；資訊窗區塊與 tick 也停。
- manifest 是使用者自己放進 `plugins/` 的，跟 agent manifest 一樣信任它；安全邊界在「面板的 JS 只能叫到表裡的指令、參數過型別檢查、不經 shell」。

#### session hook

stdin（一個 session；`segments` 是 cubi 看到的活動時段，epoch 秒，最近 7 天；`open` 是還在進行的那段）：

```json
{"id":"3d22…","name":"範例工單","cwd":"/Users/me/proj","projectDirectory":"/Users/me/proj","agent":"claude-code",
 "segments":[{"start":1762218720,"end":1762228000,"open":false},{"start":1762230000,"end":1762231500,"open":true}]}
```

stdout：

```json
{"title":"Sprint",
 "rows":[{"label":"PROJ-12","value":"範例工單 · 進行中 · 估 5 實 3 · 8h10m","url":"https://jira.example/browse/PROJ-12"},
         ["今日","2h 35m"]],
 "actions":[{"label":"同步 Jira","action":"session.sync"}],
 "error":"（選填）顯示成紅字的一行"}
```

- `rows[]`：`[label, value]` 或 `{label, value, url?}`。最多 10 列、value 最多 200 字；`url` 只收 http(s)，有的話 label 帶 `↗`、點了用系統瀏覽器開。
- `actions[]`（最多 5 個）：按鈕；`action` 必須是同一個插件的 hook 命令，按了以同一份 stdin 執行，成功才重抓 `session.info`，失敗訊息留在區塊上。
- 區塊固定多一顆「開面板」。
- stdout 超過 64 KB、不是 JSON 物件、列形狀不對、action 不合規 → 區塊顯示錯誤。
- 活動時段的切法：真事件（statusline 不算）延長當前段；與上一個事件相隔 ≥ 設定頁「多久沒動靜進入沉睡」就收段、開新段；沉默到門檻也收段（結束點是最後一個事件，不含閒置尾巴）；SessionEnd 收段；點機器人叫醒不算事件。

#### tick hook

stdin：`{"now": <epoch 秒>, "sessions": [<同上的 session 物件>…]}`，所有活著的 session（剛結束或放生的那一次也會帶到，讓最後一段能送出；同一個 session 立刻 `--resume` 回來時，那一次可能同 id 出現兩筆，插件以 id 合併即可）；`segments` 只帶 48 小時內的。stdout：

```json
{"calendar":[{"title":"PROJ-12 範例工單","start":1762218720,"end":1762228000,"notes":"https://jira.example/browse/PROJ-12","marker":"sprint:3d221898:1762218720"}]}
```

- `calendar[]`（最多 50 筆）：要出現在行事曆上的事件。`marker`（`[A-Za-z0-9:._-]{1,80}`）是這筆的穩定識別，cubi 埋在事件備註最後一行 `由 Cubi 記錄 · <marker>…`；同 marker 再送：時間變長就延長那筆事件，沒變就略過。所以**每次 tick 把該在行事曆上的東西全部重送就對了**，不必自己記哪些寫過。
- 單筆要 start < end、不超過 24 小時、start 在現在前後一年內（毫秒誤當秒會被擋），不到 60 秒不寫。
- 同標題、前後 5 分鐘內的事件會合成一筆（延長既有事件、刪掉多的，備註與記號合併，使用者自己加的備註行保留）。只併 cubi 自己寫的（備註有記號行）；別人手動建的事件不碰。
- 事件標「空閒」。EventKit 設不了「私人」，那本行事曆別分享給人。
- 行事曆沒授權或沒選（設定頁「行事曆」）時整批略過，log 每 10 分鐘提醒一次。
- 其他 tick 失敗（exit 非 0、逾時、輸出不合規）只進 log，同一類 10 分鐘一次。

#### 檔案佈局與安裝

整個插件資料夾複製到 `plugins/<id>/` 就能用（`panel.file` 相對、`run` 用 `$plugin/…`）：`scripts/install-plugin.sh docs/plugins/sprint`。插件自己的資料別放在 `plugins/<id>/` 裡（重裝會被覆蓋），放 `~/Library/Application Support/cubi/<id>/` 之類。

## 內建的 sprint 插件（`docs/plugins/sprint/`）

給兩週一個 sprint、工單在 Jira、sprint 用**標籤**（例如 `Sprint7`）標的人。Python 3 標準庫，面板單檔。

1. 安裝：`scripts/install-plugin.sh docs/plugins/sprint`，設定頁「插件 → 重新載入」。
2. Jira 帳號：`~/.config/atlassian/netrc` 一行 `machine <站台> login <email> password <API token>`（跟其他用 netrc 的工具共用；插件不會把 token 存到別處）。
3. 面板「設定」分頁：站台、專案 key、同步用 JQL（預設抓該標籤的所有單；只要自己的加 `AND assignee = currentUser()`）、估點欄位 id、實際點數欄位 id（Jira 沒有這個欄位就留空，實際點數只存本機）、回顧 Markdown 資料夾。
4. 「本期 sprint」：建 sprint（標籤要跟 Jira 一樣，起訖日期給 burndown 用）→「同步 Jira」。表格可直接填實際點數、換狀態（走 Jira transition）、「+時數」補實體會議／討論、「寫回」把實際點數寫進設定的欄位。
5. 綁定：session 名稱、git 分支、cwd 裡的單號自動綁；在面板拿掉的不會再自動加回；一個 session 綁多張單時時數預設平分，比例可改（「套用比例到本 sprint」會回算已過的段）。
6. 時數：session 活動時段依比例分攤給綁的單；手動時段整段算；種類是會議／討論的另計「會議時數」。行事曆：收掉的段（標題＝單號＋session 名）與勾了的手動時段。
7. 「回顧」：五張數字卡（完成點數、完成單數、實際/估點、每點小時、會議/總投入）、四張圖（估 vs 實、burndown、每單時數、近幾個 sprint）、四段文字與感謝名單（一行一條，離開欄位就存）、「匯出 Markdown」。
8. 資料：`~/Library/Application Support/cubi/sprint/`（config、sprints、tickets、bindings、segments，都是 JSON）。`make plugin-test` 跑它的測試。

## 命令列

```
~/Applications/Cubi.app/Contents/MacOS/cubi --version
~/Applications/Cubi.app/Contents/MacOS/cubi --hooks-status
~/Applications/Cubi.app/Contents/MacOS/cubi --hooks-plan            # 只印 diff，不寫
~/Applications/Cubi.app/Contents/MacOS/cubi --install-hooks         # 印 diff 後寫入（含備份）
~/Applications/Cubi.app/Contents/MacOS/cubi --uninstall-hooks
~/Applications/Cubi.app/Contents/MacOS/cubi --settings              # 啟動 app 並直接開設定頁
~/Applications/Cubi.app/Contents/MacOS/cubi --tool-run <id> <action> [args…]   # 走工具插件的路徑執行一條指令，印 {ok,out,err}；參數寫 - 就從 stdin 讀
~/Applications/Cubi.app/Contents/MacOS/cubi --new-session ~/proj [--continue | --resume <id>] [--prompt "第一句話"] [--terminal ghostty|terminal]
```

例：`echo '{"id":"x","name":"PROJ-12 範例","cwd":"/tmp","agent":"claude-code","segments":[]}' | cubi --tool-run sprint session.info -`。

`--hooks-plan` 與 `--install-hooks` 可加 `--retire-notify`：同時移除舊的 `notify-hook.sh` 桌面通知 hook（設定頁的同一個勾選）。CLI 跟 app 一樣以 `$HOME` 為家目錄；要對假目錄測就 `HOME=/tmp/x cubi --hooks-plan`。
