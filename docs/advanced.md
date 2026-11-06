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
| 表單與按鈕 | `cubi-form`、`cubi-field`、`cubi-inline`、`cubi-btn`（加 `primary`／`danger`／`small`／`icon`）、`cubi-tip`（ⓘ 提示） |
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
 "rows":[{"label":"PROJ-12","value":"剩 12h30m / 28h","url":"https://jira.example/browse/PROJ-12","tone":"good","progress":0.45},
         ["今日","2h 35m"],
         {"label":"計時中","value":"","clock":{"since":1762230000,"offset":0}}],
 "actions":[{"label":"同步 Jira","action":"session.sync","icon":"arrow.clockwise"}],
 "error":"（選填）顯示成紅字的一行"}
```

- `rows[]`：`[label, value]` 或 `{label, value, url?, tone?, progress?, clock?}`。最多 10 列、value 最多 200 字；`url` 只收 http(s)，有的話 label 帶 `↗`、點了用系統瀏覽器開。
  - `tone`：`good`／`warning`／`danger`／`info`／`neutral`，value 前面多一個色點、字也上色。
  - `progress`：0…1，value 底下畫一條細進度條。
  - `clock`：`{since, offset?, down?}`，cubi 每秒自己算 `offset ± (now − since)` 秒顯示（`down: true` 是倒數），不用插件一直重送。倒數低於零寫成「超 …」、最後一小時顯示到秒。`since` 是 **epoch 秒**、要在現在前後一年內，`offset` 預設 0。
  - 這三個欄位不合規**不報錯、直接略過**：`tone` 拼錯、`progress` 超出 0…1、`clock.since` 誤給毫秒，畫面上就是少了那個效果。沒出現時先檢查拼字與單位。
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
3. 面板「設定」分頁：站台、專案 key（可多個，逗號分開）、抓單用 JQL（預設 `project in ({projects}) AND labels = "{label}" AND assignee = currentUser()`）、估點欄位 id、實際點數欄位 id（Jira 沒有這個欄位就留空，實際點數只存本機）、每點小時數（預設 8）、回顧 Markdown 資料夾、整理回顧的 session 要開在哪。
4. 「總覽」分頁：建 sprint（標籤要跟 Jira 一樣，起訖日期給 burndown 用）→「同步 Jira」（「Sprint 資訊」裡的「重抓並清掉」讓 sprint 等於 JQL 結果）。上排五張數字卡（「待處理點數」＝未完成的估點，跟從今天到結束日的容量比：週一到週五、假日不扣，一個工作日 = 8 小時 ÷ 每點小時數 點；超過就紅字，整個 sprint 排的點數超過容量另標「排了 X / 容量 Y 點」；估 0 點的單在面板各處都算「未估點」）、任務分類與剩餘點數圖，下面是工單表：「實」是投入時數 ÷ 每點小時數，可手動覆寫；「剩餘」是估點換成時數減掉已投入（綠／黃／紅照剩餘比例，超過就紅字「超 …」）；換狀態走 Jira transition；「＋時數」在那張單底下展開表單，補實體會議／討論；「寫回」把實際點數寫進設定的欄位。打到一半的欄位切分頁、面板重畫都不會丟。
5. 計時：資訊窗 Sprint 區塊的 ▶ 替這個 session 綁的單開始計時（實體會議、離開電腦的討論），⏸ 停止就記成一筆「計時」手動時段（依綁定比例分給各單、寫行事曆）；計時中那列每秒走，剩餘時數跟著倒數。超過 24 小時只記 24 小時，不到 1 分鐘不記。session 結束（cubi 不再回報它、Claude Code 也不再列出它）15 分鐘後還在計時，就在它最後活動的時間自動停；只是放生或閒置的 session 不會被停。計時期間 session 自己的活動時段不會重複算、行事曆也不會重疊。面板「總覽」最上面列出所有計時中的，也能停。
6. 綁定：session 名稱、git 分支、cwd 裡的單號自動綁；資訊窗的「綁單號…」「解除 X」直接改；在面板拿掉的不會再自動加回；一個 session 綁多張單時時數預設平分，比例可改（「套用比例到本 sprint」會回算已過的段）。
7. 時數：session 活動時段依比例分攤給綁的單；手動時段整段算；種類是會議／討論的另計「會議時數」。行事曆：收掉的段（標題＝單號＋session 名）與勾了的手動時段。
8. 「回顧」：五張數字卡、任務分類甜甜圈（提早／準時完成、超時完成、未完成、超時未完成、未估點；點一類列出那些單）、burndown、近幾個 sprint、總結與四段文字＋感謝（一行一條，離開欄位就存）、「匯出 Markdown」。「用 Claude 整理回顧」把數據寫成 `<reviewDir>/<標籤>-data.md`，在設定的資料夾開一個 Claude Code session，請它寫好四段後用 `cubi --tool-run sprint review.update -` 填回面板。
9. 資料：`~/Library/Application Support/cubi/sprint/`（config、sprints、tickets、bindings、segments，都是 JSON）。`make plugin-test` 跑它的測試。

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
