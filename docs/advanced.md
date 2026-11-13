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
| `panel.style` | | `"cubi"`：注入 cubi 的 dashboard 樣式包（見下方「樣式包」）。不寫或 `null` 就不注入，既有面板不受影響 |
| `commands.<action>.run` | ✔ | argv，**不經 shell**。第一格是執行檔：絕對路徑、`~`、`$plugin/…` 或相對插件目錄的路徑（一定要含 `/`，只寫名字不會去 PATH 找）。任何一格可用 `$plugin` 代表插件目錄（只認整格 `$plugin` 或 `$plugin/…` 開頭）；`$1`…`$n` 代入呼叫端的第 n 個參數。命令的工作目錄就是插件目錄 |
| `commands.<action>.args[]` | | 每個參數的型別，數量必須跟呼叫端送的一樣：`"name"`（`[A-Za-z0-9._-]{1,64}`，不能是 `.`／`..`：檔名／資產名，走不出目錄）、`"value"`（可印字元 ≤512，不能以 `-` 開頭，所以變不成選項）、`{"enum": […]}`、`"text"`（≤256 KB，只能走 stdin） |
| `commands.<action>.stdin` | | 1-based 整數：第 n 個參數餵 stdin 而不是 argv（長內容用） |
| `commands.<action>.reveal` | | `true`：把 stdout（去頭尾空白）當路徑在 Finder 選取，回 `{ok, out: 路徑}` |
| `commands.<action>.sessionAllowed` | | `true`：這個命令可以列在 `session.new` 的 `allowActions` 裡，讓受限 session 不經任何人核准就用 `cubi --tool-run` 呼叫它。預設 `false`，寫成 `true` 以外的任何值都算沒寫。只標「agent 把結果交回來」那種命令，不要標會寫外部系統或改設定的 |
| `session.info` | | 命令名。資訊窗選到 session 時執行，之後每 `session.refresh` 秒（整數，≥10，預設 60）一次，島收起就停。見下方「session hook」 |
| `tick.action` | | 命令名。每 `tick.every` 秒（整數，≥30，預設 60）執行一次，不管島開不開。見下方「tick hook」 |

被 `session.info`／`tick.action` 指到的命令（以及資訊窗按鈕要叫的命令）叫 **hook 命令**，形狀固定：`"args": ["text"], "stdin": 1`，不能 `reveal`。app 把自己組的 JSON 餵進 stdin，讀 stdout 的 JSON。不符就整個 manifest 拒載。hook 命令有 20 秒上限，到期 SIGKILL；**不要留背景子行程**（孫行程握著 stdout 會讓 app 一直等到它結束）。面板與 `--tool-run` 叫的命令沒有時間上限。

JS 端（面板）：

```js
const bridge = window.webkit?.messageHandlers?.cubi;          // 或 manifest 的 panel.bridge
const r = await bridge.postMessage({ action: "skill.on", args: ["my-skill"] });   // {ok, out, err}
await bridge.postMessage({ action: "config.set", name: "k", value: "v" });        // 舊形狀：name/value → args
const picked = await bridge.postMessage({ action: "pick.file", args: [] });      // 內建：{ok, path, cancelled?}
await bridge.postMessage({ action: "session.new", args: [JSON.stringify({ directory: "~/proj", prompt: "第一句話" })] });
                                                                                  // 內建：在那個目錄開一個 Claude Code session（走「開新 session」同一條路）
// 從資訊窗「開面板」打開時：
window.cubiSession   // {id, name, cwd, projectDirectory, agent, segments}；之後換 session 會收到 "cubisession" 事件
```

規則：

- action 不在表裡、參數數量或型別不符 → 不執行，JS 收到 reject（錯誤訊息是中文的原因）；每次執行與拒絕都寫 `~/Library/Logs/cubi.log`。
- `pick.file`／`pick.dir`（原生選擇器）與 `session.new`（開 Claude Code session）是內建的，不用當命令宣告，也是保留字（manifest 裡定義會被拒載）。`session.new` 會把一段文字交給一個 agent，所以 manifest 要先寫 `"builtins": ["session.new"]` 才能用，而且每次都會跳確認框列出目錄與第一句話；目錄要存在，prompt 選填；失敗回 `{ok:false, err}`，取消回 `{ok:false, cancelled:true}`。
- `session.new` 的欄位只有五個，其他一律拒絕（不能傳旗標、指令或規則）：`directory`、`prompt`、`restricted`（JSON 布林）、`readDirs`（目錄路徑陣列，最多 8 個，每個都要是存在的目錄；根目錄、家目錄本身，以及家目錄下放金鑰與憑證的資料夾如 `.ssh`、`.aws`、`.gnupg` 會被拒）、`allowActions`（動作名稱陣列，最多 4 個，只能是這個插件在 manifest 標了 `"sessionAllowed": true` 的命令）。後兩個只能跟 `restricted: true` 一起用。第一句話指向別人寫的文字（工單內容、外部文件）時請帶 `restricted: true`：Cubi 用 Claude Code 的受限模式開 session，而且**完全不問人**——`claude --restricted --permission-mode dontAsk --strict-mcp-config --disable-slash-commands --tools 'Read,Grep,Glob,Bash' --settings … --add-dir … --allowedTools …`（旗標寫死在 app 裡；`--restricted` 需要 Claude Code 2.1.248 以上，下面的行為是對 2.1.322 實測的）。效果：使用者自己的允許規則、MCP、skills 與自訂指令都不套用；需要詢問的呼叫一律自動拒絕，沒有任何提示可按（逐條詢問的模式在每個提示上都有「允許並切到 accept edits」，選了之後檔案指令就不再問，而且沒有設定能拿掉它，所以不用那個模式）；能執行的只有 `allowActions` 列的動作，而且只有 `<這個 Cubi 的完整路徑> --tool-run <插件 id> <動作> <參數>` 這一種寫法——前面加 `cd … &&`、後面接 `&&`、`;`、`|`、或用 here-document 餵參數，整條都會被拒，所以給 session 的說明要把完整指令印好（路徑用環境變數 `CUBI_BIN`，app 執行每個插件命令時都會給）、參數放在單引號裡、文字裡的單引號寫成 `'\''`；Claude Code 內建不問的唯讀指令（`ls`、`cat`、`grep`、`head` 這些）仍然能跑，但讀不到工作目錄與 `readDirs` 以外的檔。確認框寫明是受限模式、不會問、能執行哪些動作、另外能讀哪些資料夾。注意 `readDirs` **不受使用者拒絕規則保護**：拒絕規則大多寫成 `**/.env` 這種相對於工作目錄的樣式，蓋不到 `--add-dir` 的資料夾，所以 `readDirs` 只能指向專門放要給 session 看的檔的資料夾（sprint 用它自己資料目錄底下的 `briefs/`，裡面只有資料檔）。路徑名稱以連續的點結尾之類、Claude Code 覺得可疑的資料夾，讀取一定要人核准，在不問的模式下等於讀不到，工作目錄與 `readDirs` 都要避開。Cubi 自己的安裝路徑若有空白或英數、`/`、`.`、`_`、`-` 以外的字元，帶 `allowActions` 的受限 session 會直接不開（那種路徑對不上放行規則）。受限模式不讀使用者的設定檔，Cubi 的 hooks 也跟著不見，所以 app 每次啟動前把 Cubi 的 hooks 加上你的拒絕規則（`~/.claude/settings.json`、工作目錄的 `.claude/settings.json` 與 `.claude/settings.local.json` 三份的 `permissions.deny` 合併；允許規則與其他設定一律不帶）寫到 `~/.cubi/restricted-settings.json` 用 `--settings` 帶進去，裡面另外固定寫 `disableAutoMode`、`disableBypassPermissionsMode`（按 shift+tab 切不到那兩種模式）與 `blockReadsOutsideWorkingDirectories`。合併時，檔案類工具（Read、Edit、Write、MultiEdit、NotebookEdit、Glob、Grep）規則裡單一斜線開頭的路徑會改寫：那種寫法是從規則所在的設定檔算起的，原樣搬到 `~/.cubi/` 會指到別處而失效，所以使用者層的 `/x` 寫成 `~/.claude/x`、專案與本機層的 `/x` 寫成 `//<工作目錄>/x`；其他寫法與其他工具的規則不動。讀哪幾份跟 Claude Code 一樣：專案層只看工作目錄本身的 `.claude/settings.json`（不往上找）；本機層在 git repo 裡讀 repo 根目錄的 `.claude/settings.local.json`，不在 repo 裡才讀工作目錄的（Claude Code 在檔案擁有者檢查不過時不讀本機層，Cubi 沒有做這個檢查，那種情況會多帶一份拒絕規則，只會更嚴）。任何一份讀不了就不開 session。這個檔只有一份、每次受限啟動前重寫，所以不要在一兩秒內從不同目錄接連開兩個受限 session。終端那一行太長時（整串指令超過約 900 位元組，回顧的第一句話就夠了），Cubi 把指令寫進 `~/.cubi/launch/<隨機名>.sh`（那個資料夾每次都設成只有你進得去、檔案只有你讀得到；超過一小時的舊檔在下一次啟動時清掉），終端裡只打一行 `source '…'`：macOS 的終端在 shell 還沒準備好時一行最多收 1024 位元組，超過的整行都不會執行。所以受限 session 的分頁上看到的是這行 `source`，完整指令在那個檔與 `~/Library/Logs/cubi.log` 的 launch 那行（寫了位元組數與檔名）（解除安裝 hooks 時刪掉）；沒安裝 Cubi hooks 時這個檔照寫照帶，只是裡面沒有 hooks（瀏海上就看不到這個 session）。受限模式管不到的：終端的環境變數、`~/.claude.json` 裡的狀態、工作目錄與家目錄的 `CLAUDE.md`，這些 session 照用。受限 session 不會跳審批卡（它什麼都不問）；relay 仍會標記它是受限的，萬一有卡，卡上也不給「總是允許」。
- 面板裡任何離開已載入 HTML 的導頁（連結、`location.href`、表單、meta refresh、`target=_blank`）一律取消；主頁面的 http(s) 目標改用系統瀏覽器開，iframe 裡的只取消。bridge 永遠只給面板自己的頁面用。
- 設定頁關掉工具後，已開著的面板送來的請求也會被拒；資訊窗區塊與 tick 也停。
- manifest 是使用者自己放進 `plugins/` 的，跟 agent manifest 一樣信任它；安全邊界在「面板的 JS 只能叫到表裡的指令、參數過型別檢查、不經 shell」。
- 面板別用 `location.reload()`：HTML 是以字串載入的，重載只會剩一張空白頁。要重抓資料就重新呼叫自己的讀取函式；改了 HTML 要看效果就關掉面板再開（每次開窗重讀檔案）。

#### 樣式包（`panel.style: "cubi"`）

cubi 在頁面載入前塞一段 `<style>` 到最前面（所以面板自己的規則照樣蓋得過去），外加 `window.cubiIcon(name, size?)` 回一段 SVG 字串。淺色、深色跟系統走，顏色跟 cubi 設定頁同一套。所有 class 都以 `cubi-` 開頭；body、按鈕、輸入框、表格的基本樣式也只套在有要求的頁面上。最小範例：`docs/plugins/example-tool/index.html`。

| 用途 | class |
|---|---|
| 版面 | `cubi-app`（左側導覽＋右邊內容）、`cubi-nav`、`cubi-nav-item`（加 `on` 是選中）、`cubi-nav-foot`、`cubi-brand`、`cubi-main`、`cubi-header`、`cubi-title`、`cubi-spacer`、`cubi-grid`、`cubi-split`、`cubi-row` |
| 卡片 | `cubi-card`、`cubi-card-head`、`cubi-card-title`、`cubi-section-title`、`cubi-muted` |
| 數字卡 | `cubi-kpis`（一排）、`cubi-kpi`、`cubi-kpi-head`、`cubi-kpi-value`、`cubi-kpi-sub`、`cubi-delta`（加 `up`／`down`／`flat`） |
| 狀態 | `cubi-pill`、`cubi-dot`、`cubi-bar`（進度條），都可加 `good`／`warning`／`danger`（`pill`、`dot` 另有 `info`） |
| 表單與按鈕 | `cubi-form`、`cubi-field`、`cubi-inline`、`cubi-btn`（加 `primary`／`danger`／`small`／`icon`）、`cubi-tip`（ⓘ 提示：`title` 的字滑上去就出現、點一下固定，用樣式包自己的框，不靠系統 tooltip） |
| 其他 | `cubi-table`、`cubi-status`（右下角訊息，加 `err` 是錯誤）、`cubi-icon` |

`cubiIcon` 的名字：`dashboard` `review` `settings` `play` `pause` `plus` `minus` `clock` `refresh` `external` `x` `check` `flag` `target` `hourglass` `users` `sparkles` `download` `info` `link`。名字不認得就回空字串。

#### session hook

stdin（一個 session；`segments` 是 cubi 看到的活動時段，epoch 秒，最近 7 天；`open` 是還在進行的那段）：

```json
{"id":"3d22…","name":"範例工單","cwd":"/Users/me/proj","projectDirectory":"/Users/me/proj","agent":"claude-code",
 "segments":[{"start":1762218720,"end":1762228000,"open":false},{"start":1762230000,"end":1762231500,"open":true}]}
```

stdout：

```json
{"title":"Sprint",
 "rows":[{"label":"PROJ-12","value":"剩 12h30m / 28h","url":"https://jira.example/browse/PROJ-12","tone":"good","progress":0.45,
          "action":{"label":"解除 PROJ-12","action":"session.unbind","arg":"PROJ-12","icon":"xmark"}},
         ["今日","2h 35m"],
         {"label":"計時中","value":"","clock":{"since":1762230000,"offset":0}}],
 "actions":[{"label":"同步 Jira","action":"session.sync","icon":"arrow.clockwise"}],
 "error":"（選填）顯示成紅字的一行"}
```

- `rows[]`：`[label, value]` 或 `{label, value, url?, tone?, progress?, clock?, action?}`。最多 10 列、value 最多 200 字；`url` 只收 http(s)，有的話 label 帶 `↗`、點了用系統瀏覽器開。
  - `tone`：`good`／`warning`／`danger`／`info`／`neutral`，value 前面多一個色點、字也上色。
  - `progress`：0…1，value 底下畫一條細進度條。
  - `clock`：`{since, offset?, down?}`，cubi 每秒自己算 `offset ± (now − since)` 秒顯示（`down: true` 是倒數），不用插件一直重送。倒數低於零寫成「超 …」、最後一小時顯示到秒。`since` 是 **epoch 秒**、要在現在前後一年內，`offset` 預設 0。
  - `action`：列尾一顆小按鈕（預設畫 ✕，`label` 是滑鼠提示），格式與檢查都跟下面的 `actions[]` 一樣：`action` 不是這個插件的 hook 命令就整份輸出拒收。一列最多一顆；適合「解除這張單」這種跟著某一列的動作。
  - `tone`／`progress`／`clock` 不合規**不報錯、直接略過**：`tone` 拼錯、`progress` 超出 0…1、`clock.since` 誤給毫秒，畫面上就是少了那個效果。沒出現時先檢查拼字與單位。
- 離線渲染（`cubi --render-panel`／`--render-widget`）時，cubi 給插件的環境多一個 `CUBI_RENDER=1`：這是乾跑：插件不該寫使用者真的資料（寫測試資料可以），也不該碰外部服務（用使用者的帳密連線、改遠端資料）。sprint 的做法：有 `CUBI_RENDER` 又沒指定 `CUBI_SPRINT_DIR` 時不存檔、不連 Jira（會回「離線渲染不連 Jira」）、不寫回顧檔，畫面照算。
- `actions[]`（最多 5 個）：按鈕；`action` 必須是同一個插件的 hook 命令，按了以同一份 stdin 執行，成功才重抓 `session.info`，失敗訊息留在區塊上。加 `"input": "提示文字"` 的按鈕會先跳系統對話框問一行字，cubi 把 tab／換行換成空白、洗掉控制字元、截到 512 字後放進 stdin JSON 的 `input` 欄；按取消就不執行。加 `"arg": "值"` 的按鈕不問人，直接把那個值當 `input` 送（例如「解除 PROJ-1」帶 `PROJ-1`）。加 `"icon": "SF Symbol 名"`（`[a-z0-9.]`，1–40 字，例如 `play.fill`）就畫成 icon 按鈕，`label` 變成滑鼠提示；名字不合規就照舊畫文字。
- 區塊固定多一顆「開面板」。
- stdout 超過 64 KB、不是 JSON 物件、列形狀不對、action 不合規 → 區塊顯示錯誤。
- 活動時段的切法：真事件（statusline 不算）延長當前段；與上一個事件相隔 ≥ 設定頁「多久沒動靜進入沉睡」就收段、開新段；沉默到門檻也收段（結束點是最後一個事件，不含閒置尾巴）；SessionEnd 收段；點機器人叫醒不算事件。

#### tick hook

stdin：`{"now": <epoch 秒>, "sessions": [<同上的 session 物件>…]}`，所有活著的 session（剛結束或放生的那一次也會帶到，讓最後一段能送出；同一個 session 立刻 `--resume` 回來時，那一次可能同 id 出現兩筆，插件以 id 合併即可）；`segments` 只帶 48 小時內的。stdout：

```json
{"calendar":[{"title":"PROJ-12 範例工單","start":1762218720,"end":1762228000,"notes":"https://jira.example/browse/PROJ-12","marker":"sprint:3d221898:1762218720"}]}
```

- `calendar[]`（最多 50 筆，多的不收）：要出現在行事曆上的事件。`marker`（`[A-Za-z0-9:._-]{1,80}`）是這筆的穩定識別，cubi 埋在事件備註最後一行 `由 Cubi 記錄 · <marker>…`；同 marker 再送：時間變長就延長那筆事件，碰到旁邊自己的事件也會併進去，都沒變就略過。所以**每次 tick 把該在行事曆上的東西全部重送就對了**，不必自己記哪些寫過。
- 單筆要 start < end、不超過 24 小時、start 在現在前後一年內（毫秒誤當秒會被擋），不到 60 秒不寫。不合規的那筆單獨略過（log 列原因），其他照寫。
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
3. 面板「設定」分頁：站台、專案 key（可多個，逗號分開）、抓單用 JQL（預設 `project in ({projects}) AND labels = "{label}" AND assignee = currentUser()`）、估點欄位 id、實際點數欄位 id（Jira 沒有這個欄位就留空，寫回鈕就不出現）、每點小時數（預設 8）、回顧 Markdown 資料夾、整理回顧的 session 要開在哪。
4. 「總覽」分頁：建 sprint（標籤要跟 Jira 一樣，起訖日期給 burndown 用）→「同步 Jira」（JQL 查不到、手動加進來的單也一起重抓；「Sprint 資訊」裡的「重抓並清掉」讓 sprint 等於 JQL 結果）。狀態色照 Jira 的狀態分類：待辦灰、進行中藍、完成綠（自訂狀態屬於哪類由 Jira 工作流程決定）。上排五張數字卡（「待處理點數」＝未完成的估點，跟從今天到結束日的容量比：週一到週五、假日不扣，一個工作日 = 8 小時 ÷ 每點小時數 點；超過就紅字，整個 sprint 排的點數超過容量另標「排了 X / 容量 Y 點」；估 0 點的單在面板各處都算「未估點」）、任務分類與剩餘點數圖，下面是工單表：「投入」寫成「6h00m · 0.75 點」（點數＝投入時數 ÷ 每點小時數，就是實際點數，不能手動改；以前填過的覆寫值不再用），點一下在那列底下展開各類工時（session 自動記的叫「Session」——同一個 session 可能先盤點再實作，不替它猜種類；手動時段照種類）與本 sprint 每一筆手動時段的備註，上方「投入」數字卡點一下展開整個 sprint 的；「剩餘」是估點換成時數減掉已投入（綠／黃／紅照剩餘比例，超過就紅字「超 …」）；換狀態走 Jira transition；「＋時數」在那張單底下展開表單，補實體會議／討論；「寫回」把這張單所有投入（含之前的 sprint，跟「剩餘」同一個基準）換算的點數寫進設定的欄位。每列最前面的 ☆／★ 是重點標記，只存在本機（`tickets.json`），不寫回 Jira；點 ★、單號、狀態、估、剩餘、投入的標題排序（點 ★ 是有星號的排前面），再點反向，沒有值的排最後，排序不記住（重開面板回到原順序）。打到一半的欄位切分頁、面板重畫都不會丟。節奏：一期兩週，週一開始、第二個週日結束；最後那一週的週四是 review 日、週五是 planning 日（滑到標題旁的日期上會寫；手填的結束日早於週四就用結束日）。「建下一期」預填下一期的標籤（結尾數字加一，`Sprint09`→`Sprint10`；結尾不是數字就留空）、開始日（現期結束後的第一個週一）與結束日（加 13 天），都可以改；新的一期在 Jira 工單貼上標籤並同步前是空的。開始日還沒到就建的那一期不會馬上切過去，到它開始那天 Cubi 自動切一次，之後手動切回舊的不會再被拉走。建立或改日期時跟別期重疊會被拒。第一個 sprint、或還沒有日期的那一期，面板會照設定的「節奏錨點」（某一期開始的週一；預設留空，留空就不預填）算出包含今天的那兩週並預填，按儲存才生效。剩餘點數圖的理想線只在上班日下降、週末持平、最後一個上班日歸零。結束日是週五而下一期隔週一才開始的舊期，面板會提醒一次把結束日改成週日，否則那個週末的工時不算進任何一期。估點可以直接在工單表的「估」那格改：按 Enter 或離開那一格就寫回 Jira 的估點欄位，寫成功面板才跟著變（Jira 是準的，寫不進去就回到原值並顯示 Jira 的錯誤）；要是大於 0 的數字（全形數字也行，逗號、中間有空白、`1e3` 不行），清空代表未估點，不能填 0。設定頁填了「實際時數欄位」（Jira 上放實際時數的數字欄位）之後，每列多一顆「寫回時數」（沙漏）：把這張單所有投入（含之前的 sprint，計時、手動、session 自動記的都算）換成小時、四捨五入到小數兩位，蓋掉那個欄位原有的數字，別人手填的也會被蓋掉；還沒有投入的單不能寫。這兩個寫回連 Jira 的那幾秒不佔著資料檔，資訊窗與計時照常；寫回的單號必須是面板已經認得的工單。設定頁再打開「自動寫回時數」（預設關）的話，不用按沙漏：停止計時、新增／修改／刪除手動時段時，那張單先記成「等寫回」，Cubi 每分鐘的定時執行替最多 3 張寫進 Jira（每張等 Jira 5 秒，累計超過 10 秒就留到下一分鐘），寫的是當下的總投入時數，刪到沒有時數就寫 0；session 自動記的時段變長不算觸發，下次觸發或按沙漏時一起寫進去。連不上或逾時會一直重試；Jira 明確拒絕（沒有編輯權、欄位不在畫面上、查無此單）就停，總覽最上面顯示「N 張時數尚未寫回」與最後一次錯誤，按「重試」再排一次，那張單之後有新的工時也會再試。注意它覆蓋的是「這台機器記到的時數」：兩個人對同一張單都開著自動寫回會互相蓋掉。在 Jira 被刪掉（或你不再有權限看）的單：Jira 的批次查詢會默默略過查不到的單，所以同步時沒回來的單會逐張再問一次，確定是 404 才標成查不到（一次同步最多確認 20 張，資訊窗那邊一次 3 張，剩下的下次同步再確認；連不上 Jira 時什麼都不標）。標了以後那一列的狀態是紅色的「Jira 查不到」，留著最後一次讀到的資料，估點、換狀態、兩種寫回都停用，等著寫回時數的也取消；它仍算在這一期的數字裡，因為沒有權限和被刪除在 Jira 看起來一樣，要不要拿掉由你決定。之後 Jira 又查得到的話，把單號再加一次就恢復。每列最右邊的 ✕ 把那張單移出這一期（`ticket.remove`）：只改這一期的清單，工單資料、工時紀錄、綁定都不動，不連 Jira；那張單在這一期有工時會提示一句（移出後不算進這一期的投入，加回來就恢復）；它在 Jira 還貼著本期標籤的話，下次同步會自己回來。寫回估點、實際點數、實際時數時，Jira 如果回「Field … cannot be set. It is not on the appropriate screen, or unknown.」，面板會先用中文說明是這張單的專案或類型沒有那個欄位，原文附在後面。
5. 計時：資訊窗 Sprint 區塊的 ▶ 替這個 session 綁的單開始計時（實體會議、離開電腦的討論），⏸ 停止就記成一筆「計時」手動時段（依綁定比例分給各單、寫行事曆）；計時中那列每秒走，剩餘時數跟著倒數。超過 24 小時只記 24 小時，不到 1 分鐘不記。session 結束（cubi 不再回報它、Claude Code 也不再列出它）15 分鐘後還在計時，就在它最後活動的時間自動停；只是放生或閒置的 session 不會被停。計時期間 session 自己的活動時段不會重複算、行事曆也不會重疊。面板「總覽」最上面列出所有計時中的，也能停。
6. 綁定：session 名稱、git 分支、cwd 裡的單號自動綁；資訊窗的「綁單號…」與每張單那列尾端的 ✕ 直接改（資訊窗最多列 8 張，多的寫「還有 N 張」；面板「綁定總覽」列出這個 sprint 有活動（或正在計時、或面板就是從它開的）的 session 綁的單與比例，任一張都能解）；計時停下來時依「那一刻」綁的單與比例分（誤解綁再綁回不會白跑），全部解掉就照樣計時、停下來不記（按鈕寫「不記」）；在面板拿掉的不會再自動加回；一個 session 綁多張單時時數預設平分，比例可改（「套用比例到本 sprint」會回算已過的段）。
7. 時數：session 活動時段依比例分攤給綁的單；手動時段整段算；同一張單的同一段時間只算一次（這版之後新增的紀錄才這樣算：先記的照算，後記的只補沒被算到的部分；同一時刻這張單從各紀錄分到的比例加起來最多 100%，例如兩個 session 各分 50% 就算滿；不同單之間不比，因為可以同時做好幾張；之前的紀錄與已寫進 Jira 的實際時數照舊，不回頭重算），時段清單會標「重疊 N 不算」或「跟其他紀錄重疊」；種類是會議／討論的另計「會議時數」。「沒有單號的工作」卡片記沒有 Jira 單的時段（PM 開的異常會議、支援、面試…）：要寫說明，掛在開始時間落在的那個 sprint（都沒落在就掛目前的）；勾「計入工時」的算進「投入」（會議類也算進「會議」），不算進任何一張單、不影響實際／估點比例與容量；也能勾寫進行事曆（標題＝說明＋種類）。行事曆：收掉的段（標題＝單號＋session 名）與勾了的手動時段。沒有單號的工作算在哪一期是每次照開始時間對各期日期算的（補記之後才建的那一期也會拿到落在它日期裡的時段）；沒有任何一期涵蓋那個時間才用記下時的那一期。時數的表單都用小時（可以有小數）。工單那列的「＋」只要填時數：算成剛剛結束、往前推那麼久；要指定開始時間、種類、備註或不寫行事曆，按「進階」。命令列一樣：`time.add` 有 `key` 而沒給 `start` 就是剛剛結束。已經記下的手動時段在「手動時段」與「沒有單號的工作」裡按「改」可以改時數、開始時間、種類、備註（`time.update`，只送有改的欄位）；計時記下的那種只能改長度或刪除，因為它的分鐘數要跟同一個 session 自動記的時段對起來。行事曆不會跟著改：Cubi 對自己寫過的事件只會延長，所以除了「48 小時內的時段單純變長」之外，改過一筆有寫進行事曆的時段後面板會提醒你手動調整或刪除舊事件。
8. 「回顧」：五張數字卡、任務分類甜甜圈（提早／準時完成、超時完成、未完成、超時未完成、未估點；點一類列出那些單）、burndown、近幾個 sprint、總結與四段文字＋感謝（一行一條，離開欄位就存）、「匯出 Markdown」。「用 Claude 整理」把數據寫成插件資料目錄底下的 `briefs/<標籤>-data.md`，在設定的資料夾開一個 Claude Code session，請它寫好四段後用 `<cubi 的完整路徑> --tool-run sprint review.update '<JSON>'` 這一條指令填回面板。這個 session 一律用受限模式開（資料檔裡有 Jira 上別人寫的原文，放在兩行 `<<<第三方資料…>>>` 記號之間）：它只讀資料檔、用那一條 `review.update` 指令寫回面板，不寫檔，而且不會問你任何事——寫回這一步不經過你核准，其他指令一律跑不了（最壞的情況是面板上的回顧文字被寫成奇怪的內容，重按一次就蓋掉）；開啟後 3 分鐘還沒收到回顧，面板右下角會提示你去終端看那個 session（它的寫回指令寫錯被拒時，這邊不會有別的訊號），請它照資料檔的寫法重寫；收到後提示就換成「Claude 寫回來了」。要 Markdown 就按面板的「匯出 Markdown」。資料檔寫在插件自己的資料目錄 `~/Library/Application Support/cubi/sprint/briefs/`，不寫進你的回顧資料夾。review 提醒：每一期在 review 日的行事曆上有一筆「Sprint review」（時間與長度在設定頁，預設 10:00、30 分鐘；時間留空就不寫）。這筆事件每期只交給 Cubi 寫一次——從該期第一天起的第一次定時執行，之後 10 分鐘內重送同一筆（補掉一時寫不進去的情況），然後不再送，所以你可以把它拖到實際開會的時間、搬到別本行事曆或刪掉，不會再長一筆；改設定只影響還沒寫出事件的期。行事曆上沒看到（當時還沒授權行事曆）就按面板提醒旁的「重新寫入行事曆」，下一分鐘照現在的 review 日與時間再寫一次；舊事件若被移動過或 review 日、時間改過，會多出一筆，要手動刪舊的。事件寫出後又改了那一期的結束日，行事曆上的事件不會跟著動，面板會提醒一次。review 日當天資訊窗的 Sprint 區塊第一列是「今天 review」（那天工單最多列 7 張）；從 review 日到那一期最後一天，總覽最上面有提醒與「產生回顧」。匯出的 Markdown 與交給 Claude 的資料檔第一段都寫「產生於 …，數字截至這個時間」，之後記的工時只會出現在面板上。
9. AI 估點：設定頁「AI 估點讀的程式碼資料夾」填了以後（預設留空，留空時按鈕是灰的），工單表每列多一顆 ✨。按下去，插件先向 Jira 讀這張單的摘要、類型、狀態、描述，連同目前估點、已投入時數、本期其他已估點的單（當尺度參考），寫成 `briefs/<單號>-estimate.md`，再在那個資料夾開一個受限的 Claude Code session：它讀資料檔與資料夾裡的程式碼，只能用 `<cubi 的完整路徑> --tool-run sprint estimate.suggest '<JSON>'` 這一條指令交回點數、把握（高／中／低）與兩三句理由，而且只收面板剛開過資料檔的那張單；找不到相關程式碼時要在理由裡講明、把握寫低。Jira 上的工單內容放在兩行 `<<<第三方資料…>>>` 記號之間。建議出現在那一列底下：按「採用」走跟手動改估點一樣的寫回，只把點數寫進 Jira；按「不要」就清掉，什麼都不送。還沒按「採用」或「不要」之前，可以在那個 session 裡追問、請它重送，新的建議會蓋掉舊的（第一筆回來後面板仍每 30 秒看一次，看到新的就換上並提示「AI 估點更新了」，直到按了「採用」或「不要」、或開始等之後滿一小時）；按了之後就不再收，採用後想改，直接在面板改估點，或再按一次 ✨ 重估（新的資料檔會寫上目前的估點）。設定頁的「補充估點規則」（500 字內，不能有 `<<<` 或 `>>>`）會原樣、每行前面加 `> `，放進資料檔「怎麼估」那一節的最後，在別人寫的原文記號外面；它只改估法，改不了 session 能讀什麼、能跑什麼；留空時資料檔跟沒有這個設定時一字不差。理由只存在這台電腦、只在面板顯示，不送 Jira。等待方式跟「用 Claude 整理」一樣：每 30 秒看一次，3 分鐘沒收到就在右下角提示去終端看；同時只追最後開的那一個，等待中可以按「不等了」；同一張單在等的一小時內 ✨ 是灰的（「已在估，要重開請先按「不等了」」），連點也只會開一個 session，超過一小時視為那個 session 不會回來了，可以重開；已經有建議的單可以直接重估。**這個資料夾裡的檔案 Claude 都讀得到**（受限模式只擋工作目錄以外的讀取，擋不了資料夾裡的 `.env` 之類），請勿選含機密的資料夾。
10. 沒有估點欄位的單（專案或單的類型的編輯畫面上沒有那個欄位）：改估點或按「採用」時照常先寫欄位；Jira 回 400，插件再讀這張單的 editmeta（編輯畫面有哪些欄位，看欄位 id，跟 Jira 的語系無關），確定沒有估點欄位才在那一列底下問你，其他情況（欄位其實在、editmeta 讀不到、網路或權限錯誤、清空估點）照原本的錯誤顯示。那一列給出整則留言的原文：粗體「【估點】本單 N 點（1 點＝1 人天）」接「。此單類型沒有估點欄位，所以用留言記錄，供 sprint 統計用。」，只有點數，不放 AI 的理由；三個按鈕：「留言到 Jira」才會寫、「只記在本機」只存這台電腦（例如你已經自己留過言）、「取消」什麼都不動。Cubi 記得自己發的那一則留言的 id，之後改估會編輯那一則，不碰別人或你手寫的留言；改之前那一列會顯示 Jira 上目前的文字，被改過會特別說；那則留言被刪了，那一列會說會發一則新的，按下才發；在你看到確認列之後才被刪的，按下時什麼都不寫，改成問你要不要發新的。這些單的估點存在本機，同步不會蓋掉（Jira 沒有值）；不會從留言讀回估點。估點格滑過去會說它記在留言還是只在本機。
11. 資料：`~/Library/Application Support/cubi/sprint/`（config、sprints、tickets、bindings、segments，都是 JSON）。`make plugin-test` 跑它的測試。

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
