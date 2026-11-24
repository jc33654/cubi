# 套件規格參考（schema 1）

第一次做套件先看 [guide.md](guide.md)。這份是逐欄位的規格；給工具讀的版本是 [manifest.schema.json](manifest.schema.json)（manifest）、[hook-io.schema.json](hook-io.schema.json)（hook 的 stdin／stdout）、[bridge.d.ts](bridge.d.ts)（面板 JS）。

- 「出處」是跟這份文件同一個 commit 的程式行號，每個行為都對得到那一行；改程式動到行號時，這份文件跟著改。
- 標「實測」的是實際跑過；沒標的是讀程式碼得到的。
- 穩定度：**stable** 在 schema 1 內保持相容；**experimental** 任何版本都可能改；**deprecated** 還能用，之後會拿掉。

## 相容承諾

- `schema` 是 manifest 格式的版本，沒寫等於 1（`Sources/CubiKit/PluginManifest.swift:61`）。這個 Cubi 認得到 1（`PluginManifest.swift:9`）；寫更大的數字會被拒載，並請你更新 Cubi；不是 1 以上的整數也拒載。
- **stable** 欄位在 schema 1 內不會改意思、不會被拿掉。要淘汰時，先在這份文件標成 deprecated，並且至少保留一個版本照常能用，之後才拿掉。改變不相容就升 `schema`。
- **experimental** 的欄位與整個 agent 套件，任何版本都可能改，不另行通知。標準：等有第二個真實套件也在用，才考慮升成 stable。
- 新增欄位不算破壞：舊的 Cubi 遇到不認得的欄位只警告、照樣載入（`PluginManifest.swift:104-122`）。

## 載入規則

| 規則 | 說明 | 穩定度 | 出處 |
|---|---|---|---|
| 位置 | `~/Library/Application Support/cubi/plugins/<id>/manifest.json`；設定頁「插件」的「重新載入」重掃一次 | stable | `Sources/cubi/Plugins/PluginRegistry.swift:13-14`、`:42` |
| 資料夾名 | 必須等於 `id`，不一樣就拒載 | stable | `PluginManifest.swift:71` |
| `kind` | `tool`、`agent` 或不寫（等於 agent）；其他值拒載 | stable | `PluginManifest.swift:66-70` |
| 不認得的欄位 | 照樣載入，但設定頁用黃字列出，log 寫 `plugin <資料夾> warning:`；以 `x-` 開頭的是你自己的，不警告 | stable | `PluginManifest.swift:112`、`PluginRegistry.swift:66`、`Sources/cubi/Settings/PluginsSection.swift:35` |
| 拒載 | 原因用紅字列在設定頁，log 寫 `plugin <資料夾> rejected:` | stable | `PluginRegistry.swift:65`、`PluginsSection.swift:30` |
| id 命名空間 | 兩種套件共用；跟內建的 `claude-code` 撞名就拒載 | stable | `PluginRegistry.swift:46-49` |
| 預設開關 | 工具套件預設開，agent 套件預設關。在設定頁關掉工具套件後，已開著的面板送來的請求也會被拒，資訊窗區塊與 tick 也停 | stable | `PluginRegistry.swift:78`、`ToolPanel.swift:153-156` |
| 檢查指令 | `cubi --validate-plugin <資料夾>`：照上面的規則檢查，加上面板檔、每個命令與 `service` 的執行檔在不在、能不能執行；不開 app、不寫 log。結束碼 0 載得進來（可能有警告）、1 有錯、2 用法錯 | stable | `Sources/cubi/main.swift:25-38`、`PluginManifest.swift:132-172` |

schema 檔比 Cubi 嚴格一點：不認得的欄位在 schema 是錯誤，在 Cubi 只是警告；`service.run` 裡 `$` 後面接一串長到放不進整數的數字，schema 會拒，Cubi 當一般字串。有些規則 schema 寫不出來，請用 `--validate-plugin` 檢查：資料夾名要等於 `id`、`text` 參數要走 stdin、`stdin` 不能超過參數數量、`$1`…`$n` 要有對應參數、hook 命令的形狀（包括 `session.info`／`tick.action` 指到的命令存在）、agent 套件 `install.entries[].command` 要含 `cubi-hook --agent <id> `、檔案在不在。

## 工具套件 manifest

範例：`docs/plugins/example-tool/`（最小）、`docs/plugins/sprint/`（完整）。

| 欄位 | 必填 | 說明 | 穩定度 | 出處 |
|---|---|---|---|---|
| `schema` | | 見「相容承諾」 | stable | `PluginManifest.swift:61-64` |
| `kind` | ✔ | `"tool"` | stable | `PluginManifest.swift:66-70` |
| `id` | ✔ | `[a-z0-9-]`，1–24 字，等於資料夾名 | stable | `Sources/CubiKit/ToolPlugin+Load.swift:31-32`、`Sources/CubiKit/AgentPlugin.swift:77-78` |
| `name` | ✔ | 視窗標題、選單文字、資訊窗區塊標題 | stable | `ToolPlugin+Load.swift:33` |
| `panel.file` | ✔ | 一個 HTML 檔：相對套件資料夾、`~` 或絕對路徑；每次開窗重讀。以字串載入、沒有基底網址（origin 是 null），**同資料夾的 js、css、圖片用相對路徑載不到，要全部寫在這個 HTML 裡**（實測：同資料夾的 `app.js` 沒有載入）。外部網址的 script、img、fetch 不擋：面板跟 manifest 一樣是你自己放的，一樣信任 | stable | `ToolPlugin+Load.swift:34`、`Sources/cubi/Plugins/ToolPanel.swift:75-77` |
| `panel.width`、`panel.height` | | 視窗大小，預設 900×640 | stable | `ToolPlugin+Load.swift:43-44` |
| `panel.style` | | `"cubi"`：注入樣式包（見「樣式包」）；不寫或 `null` 就不注入，既有面板不受影響 | stable | `ToolPlugin+Load.swift:36-41`、`ToolPanel.swift:104-106` |
| `panel.bridge` | | JS 用的 handler 名，預設 `cubi`；既有面板寫死別的名字時在這裡宣告，不用改面板 | experimental | `ToolPlugin+Load.swift:45`、`ToolPanel.swift:58` |
| `commands.<action>` | | 動作名稱：小寫英數與 `.`、`_`、`-`，第一個字要是英數，1–64 字；`pick.file`、`pick.dir`、`session.new` 是內建的，不能自己定義 | stable | `ToolPlugin+Load.swift:57-58`、`PluginManifest.swift:178-182` |
| `commands.<action>.run` | ✔ | argv，**不經 shell**。第一格是執行檔：絕對路徑、`~`、`$plugin/…` 或含 `/` 的相對路徑，只寫名字不會去 PATH 找。自己寫的腳本要 `chmod +x`，或第一格寫直譯器，例如 `["/usr/bin/python3", "$plugin/main.py"]`。任何一格可用 `$plugin`（整格是它或以 `$plugin/` 開頭）；`$1`…`$n` 換成呼叫端的第 n 個參數；走 stdin 的那個參數不能再寫成 `$n`（會拒載）。工作目錄是套件資料夾 | stable | `ToolPlugin+Load.swift:59-65`、`:88-93`、`:142-152`、`Sources/cubi/Plugins/ToolRunner.swift:45` |
| `commands.<action>.args[]`：`"text"` | | ≤256 KB，只能走 stdin | stable | `ToolPlugin+Load.swift:85-87`、`ToolPlugin+Invoke.swift:49-50` |
| `commands.<action>.args[]`：`"value"` | | 可印字元，1–512 字，不能以 `-` 開頭（變不成選項） | stable | `ToolPlugin+Invoke.swift:44-48` |
| `commands.<action>.args[]`：`"name"` | | `[A-Za-z0-9._-]`，1–64 字，不能是 `.`／`..`（走不出目錄） | experimental | `ToolPlugin+Invoke.swift:39-43` |
| `commands.<action>.args[]`：`{"enum": […]}` | | 只能是列出的字串之一 | experimental | `ToolPlugin+Load.swift:73-77`、`ToolPlugin+Invoke.swift:51-52` |
| `commands.<action>.stdin` | | 1-based 整數：第 n 個參數餵 stdin、不放 argv。hook 命令與面板指令都適用，例如面板要收長文字就寫 `"args": ["text"], "stdin": 1`（依據：兩個以上套件使用）。送進去的是那個字串的 UTF-8 原樣：結尾不補換行、CRLF 不轉換（實測：面板、`--tool-run` 參數、`--tool-run -` 三種來源都一樣）；Cubi 自己組給 hook 的 JSON 結尾也沒有換行 | stable | `ToolPlugin+Load.swift:82-84`、`ToolRunner.swift:79-81`、`PluginIO.swift:251-255` |
| `commands.<action>.reveal` | | `true`：stdout 去頭尾空白當路徑，在 Finder 選取；回 `{ok, out: 路徑}` | stable | `ToolPlugin+Load.swift:95`、`ToolPanel.swift:259-262` |
| `commands.<action>.sessionAllowed` | | 只有 `true` 算數：受限 session 可以不經核准跑它（見「受限 session」）。只標「把結果交回來」的命令，不要標會寫外部系統或改設定的 | experimental | `ToolPlugin+Load.swift:95` |
| `session.info` | | hook 命令名：資訊窗選到 session 時執行 | stable | `ToolPlugin+Load.swift:99-103` |
| `session.refresh` | | 秒，整數，≥10，預設 60；資訊窗離開畫面（換 session、島收起）就停 | stable | `ToolPlugin+Load.swift:117-122`、`Sources/cubi/Island/SessionWidgetView.swift:50-57` |
| `tick.action` | | hook 命令名：定時執行，不管島開不開 | experimental | `ToolPlugin+Load.swift:105-109` |
| `tick.every` | | 秒，整數，≥30，預設 60。Cubi 每 30 秒檢查一次，所以實際間隔是 30 的倍數往上湊（寫 45 約每 60 秒一次） | experimental | `Sources/cubi/Plugins/PluginTicker.swift:25`、`:43` |
| `builtins` | | 目前只收 `"session.new"`：要用它得先在這裡寫 | experimental | `ToolPlugin+Load.swift:50-55` |
| `service` | | 背景服務：套件開著、而且使用者在設定 › 插件打開這個套件的「背景服務」開關（預設關）時，由 Cubi 啟動並看管的一支程式，見「背景服務」。不認得 `service` 的 Cubi（0.2.0 和更早的版本）會在設定頁與 `--validate-plugin` 顯示黃字「不認得的欄位 service」，套件其他部分照常載入，背景服務不會啟動；它也不在 `commands` 裡，所以面板與 `--tool-run` 都叫不到它 | experimental | `ToolPlugin+Load.swift:110`、`ToolPlugin+Service.swift:26-58`、`Sources/cubi/Plugins/PluginRegistry.swift:92-96` |
| `service.run` | ✔（寫了 `service` 時） | 它自己的 argv，寫法跟 `commands.<action>.run` 一樣：不經 shell；執行檔要是路徑（絕對、`~`、`$plugin/…` 或含 `/` 的相對路徑），只寫名字不會去 PATH 或 `commands` 找；`$plugin` 是套件資料夾。比 `commands` 嚴兩點：每一格都要是字串（`commands` 的非字串格會被略過），而且不能有 `$1`…`$n`（沒有參數，stdin 留給 Cubi 跟它溝通）。`--validate-plugin` 會檢查執行檔在不在、能不能執行 | experimental | `ToolPlugin+Service.swift:28-40`、`PluginManifest.swift:140` |
| `service.restart` | | `on-failure`（預設）或 `never`。以 0 結束算是自己停，不重新啟動；其他結束在 `on-failure` 時依 1、2、4、8 秒重新啟動，10 分鐘內第 5 次就不再啟動。見「背景服務」 | experimental | `ToolPlugin+Service.swift:16-20`、`:41-47`、`ServiceSupervision.swift:20-24` |
| `service.events` | ✔（寫了 `service` 時） | 它可以在 stdout 請 Cubi 做的事：`notice`、`present`、`state`、`log`、`reply` 裡挑，至少一個、不能重複；沒列的會被丟掉。格式見「背景服務」 | experimental | `ToolPlugin+Service.swift:22-24`、`:48-56`、`ServiceProtocol.swift:65` |

**hook 命令**：`session.info`、`tick.action` 與資訊窗按鈕叫的命令，形狀固定是 `"args": ["text"], "stdin": 1`，不能 `reveal`，不符就整份 manifest 拒載（`ToolPlugin+Load.swift:126-130`）。app 把 JSON 餵進 stdin、讀 stdout 的 JSON。hook 命令有 20 秒上限，到期整組行程 SIGKILL（`ToolRunner.swift:15`、`:67-78`）；**不要留背景子行程**，孫行程握著 stdout 會讓 app 一直等到時限。面板與 `--tool-run` 叫的命令沒有時限。

**環境變數**（experimental）：每個命令都有 `CUBI_BIN`，是正在跑的 cubi 執行檔路徑（`ToolRunner.swift:48`）。離線渲染（`--render-panel`／`--render-widget`）時多一個 `CUBI_RENDER=1`（`main.swift:65-67`），代表乾跑：不該寫使用者真的資料（寫測試資料可以），也不該碰外部服務（用使用者的帳密連線、改遠端資料）。建議的寫法是腳本讀一個自己的環境變數決定資料夾，有 `CUBI_RENDER` 又沒設那個變數時就不寫檔（範例在 [guide.md](guide.md#下一步)）。sprint 的做法：有 `CUBI_RENDER` 又沒指定 `CUBI_SPRINT_DIR` 時不存檔、不連 Jira、不寫回顧檔，畫面照算。

## 面板 JS（bridge）

型別見 [bridge.d.ts](bridge.d.ts)。

```js
const bridge = window.webkit?.messageHandlers?.cubi;          // 或 manifest 的 panel.bridge
const r = await bridge.postMessage({ action: "skill.on", args: ["my-skill"] });   // {ok, out, err}
const picked = await bridge.postMessage({ action: "pick.file", args: [] });      // 內建：{ok, path, cancelled?}
await bridge.postMessage({ action: "session.new", args: [JSON.stringify({ directory: "~/proj", prompt: "第一句話" })] });
// 從資訊窗「開面板」打開時：
window.cubiSession   // {id, name, cwd, projectDirectory, agent, segments}；之後換 session 會收到 "cubisession" 事件
```

| 項目 | 說明 | 穩定度 | 出處 |
|---|---|---|---|
| `{action, args}` → `{ok, out, err}` | `ok` 是 exit code 為 0 | stable | `ToolPanel.swift:235-268` |
| 拒絕 | 動作不在表裡、參數數量或型別不符、套件在設定頁關掉 → 不執行，Promise reject，原因是中文。每次執行與拒絕都寫進 log | stable | `ToolPanel.swift:149-156`、`:246-252`、`ToolPlugin+Invoke.swift:21-35` |
| 舊形狀 `{action, name, value}` | name、value 依序當成 args | deprecated | `ToolPanel.swift:240-244` |
| `pick.file`、`pick.dir` | 原生選擇器，回 `{ok, path, cancelled?}` | experimental | `ToolPanel.swift:222-233` |
| `session.new` | 見「受限 session」 | experimental | `ToolPanel.swift:162-216` |
| `window.cubiSession`、`cubisession` 事件 | 從資訊窗打開時設定；面板已開時換 session 不重載頁面 | stable | `ToolPanel.swift:45-53`、`:107-109` |
| 導頁 | 任何離開已載入 HTML 的導頁一律取消；主頁面的 http(s) 改用系統瀏覽器開，iframe 裡的只取消。bridge 只給面板自己的頁面用 | stable | `ToolPanel.swift:117-129` |
| `location.reload()` | 別用：HTML 以字串載入，重載只剩空白頁。要重抓資料就重新呼叫自己的讀取函式；改了 HTML 要看效果就關掉面板再開（每次開窗重讀檔案） | stable | `ToolPanel.swift:75-77` |

安全邊界：manifest 與面板是你自己放進 `plugins/` 的，Cubi 信任它們；邊界在「面板的 JS 只能叫到表裡的指令、參數過型別檢查、不經 shell」。

## 樣式包（`panel.style: "cubi"`）

stable，class 名稱清單本身也在承諾範圍內。Cubi 在頁面載入前塞一段 `<style>` 到最前面（面板自己的規則照樣蓋得過去），外加 `window.cubiIcon(name, size?)` 回一段 SVG 字串（`ToolPanel.swift:104-106`、`Sources/cubi/Plugins/PanelStyleKit.swift`）。淺色、深色跟系統走，顏色跟 Cubi 設定頁同一套。所有 class 以 `cubi-` 開頭；body、按鈕、輸入框、表格的基本樣式也只套在有要求的頁面。最小範例：`docs/plugins/example-tool/index.html`。

| 用途 | class |
|---|---|
| 版面 | `cubi-app`（左側導覽＋右邊內容）、`cubi-nav`、`cubi-nav-item`（加 `on` 是選中）、`cubi-nav-foot`、`cubi-brand`、`cubi-main`、`cubi-header`、`cubi-title`、`cubi-spacer`、`cubi-grid`、`cubi-split`、`cubi-row` |
| 卡片 | `cubi-card`、`cubi-card-head`、`cubi-card-title`、`cubi-section-title`、`cubi-muted` |
| 數字卡 | `cubi-kpis`（一排）、`cubi-kpi`、`cubi-kpi-head`、`cubi-kpi-value`、`cubi-kpi-sub`、`cubi-delta`（加 `up`／`down`／`flat`） |
| 狀態 | `cubi-pill`、`cubi-dot`、`cubi-bar`（進度條），都可加 `good`／`warning`／`danger`（`pill`、`dot` 另有 `info`） |
| 表單與按鈕 | `cubi-form`、`cubi-field`、`cubi-inline`、`cubi-btn`（加 `primary`／`danger`／`small`／`icon`）、`cubi-tip`（ⓘ 提示：`title` 的字滑上去就出現、點一下固定，用樣式包自己的框，不靠系統 tooltip） |
| 其他 | `cubi-table`、`cubi-status`（右下角訊息，加 `err` 是錯誤）、`cubi-icon` |

`cubiIcon` 的名字：`dashboard` `review` `settings` `play` `pause` `plus` `minus` `clock` `refresh` `external` `x` `check` `flag` `target` `hourglass` `users` `sparkles` `download` `info` `link`。名字不認得就回空字串（`PanelStyleKit.swift:17-19`）。

## session hook

stdin 是一個 session（型別：`hook-io.schema.json#/$defs/sessionInput`，`Sources/CubiKit/PluginIO.swift:31-47`）：

```json
{"id":"3d22…","name":"範例工單","cwd":"/Users/me/proj","projectDirectory":"/Users/me/proj","agent":"claude-code",
 "segments":[{"start":1762218720,"end":1762228000,"open":false},{"start":1762230000,"end":1762231500,"open":true}]}
```

- `segments`：Cubi 看到的活動時段，epoch 秒，最近 7 天；`open` 是還在進行的那段（`Sources/CubiKit/SessionStore.swift:251`、`Sources/cubi/SessionCoordinator+Plugins.swift:35-45`）。
- `cwd`、`projectDirectory` 沒有值時整個欄位不出現（實測：`--render-widget` 給的 stdin 就沒有這兩個欄位）。
- `input` 只在按了帶 `input`／`arg` 的按鈕時才有。

stdout（型別：`hook-io.schema.json#/$defs/widgetOutput`，`PluginIO.swift:133-153`）：

```json
{"title":"Sprint",
 "rows":[{"label":"PROJ-12","value":"剩 12h30m / 28h","url":"https://jira.example/browse/PROJ-12","tone":"good","progress":0.45,
          "action":{"label":"解除 PROJ-12","action":"session.unbind","arg":"PROJ-12","icon":"xmark"}},
         ["今日","2h 35m"],
         {"label":"計時中","value":"","clock":{"since":1762230000,"offset":0}}],
 "actions":[{"label":"同步 Jira","action":"session.sync","icon":"arrow.clockwise"}],
 "error":"（選填）顯示成紅字的一行"}
```

| 欄位 | 說明 | 穩定度 | 出處 |
|---|---|---|---|
| `title` | 截到 60 字 | stable | `PluginIO.swift:12`、`:142` |
| `rows[]` | `[label, value]` 或 `{label, value, url?, …}`；最多 10 列，value 最多 200 字；`url` 只收 http(s)，label 帶 `↗`、點了用瀏覽器開 | stable | `PluginIO.swift:7`、`:9`、`:261-277`、`Sources/cubi/Island/SessionWidgetView.swift:75` |
| `rows[].tone` | `good`／`warning`／`danger`／`info`／`neutral`：value 前多一個色點、字上色 | experimental | `PluginIO.swift:77`、`:269` |
| `rows[].progress` | 0…1：value 底下一條細進度條 | experimental | `PluginIO.swift:270` |
| `rows[].clock` | `{since, offset?, down?}`：Cubi 每秒算 `offset ± (now − since)` 秒顯示（`down: true` 倒數）。倒數低於零寫成「超 …」、最後一小時顯示到秒。`since` 是 epoch 秒、在現在前後一年內 | experimental | `PluginIO.swift:81-111` |
| `rows[].action` | 列尾一顆小按鈕（預設畫 ✕，`label` 是滑鼠提示；島浮動時滑鼠提示目前不顯示），規則同 `actions[]`；一列最多一顆，適合「解除這張單」這種跟著某一列的動作 | experimental | `PluginIO.swift:138` |
| `actions[]` | 按鈕，最多 5 個；`action` 必須是同一個套件的 hook 命令，否則整份輸出拒收。按了以同一份 stdin 執行，成功才重抓 `session.info`，失敗訊息留在區塊上 | experimental | `PluginIO.swift:8`、`:141`、`:146-153`、`Sources/cubi/Plugins/SessionWidgetStore.swift:42-51` |
| `actions[].input` | 先跳對話框問一行字：tab、換行換成空白，洗掉控制字元，截到 512 字，放進 stdin 的 `input`；取消就不執行 | experimental | `PluginIO.swift:221-227`、`SessionWidgetStore.swift:45-47` |
| `actions[].arg` | 不問人，直接把這個值當 `input` 送（`input` 有寫時忽略） | experimental | `PluginIO.swift:151` |
| `actions[].icon` | SF Symbol 名（`[a-z0-9.]`，1–40 字）：畫成 icon 按鈕，`label` 變成滑鼠提示；不合規就照舊畫文字 | experimental | `PluginIO.swift:152`、`:230-235` |
| `error` | 顯示成紅字一行 | stable | `PluginIO.swift:143` |

- `tone`／`progress`／`clock` 不合規**不報錯、直接略過**：`tone` 拼錯、`progress` 超出 0…1、`clock.since` 誤給毫秒，畫面上就是少了那個效果；沒出現時先檢查拼字與單位。schema 檔把它們當錯誤，比 Cubi 嚴格。
- stdout 超過 64 KB、不是 JSON 物件、列的形狀不對、action 不合規 → 區塊顯示錯誤（`PluginIO.swift:6`、`:243-249`）。
- 區塊固定多一顆「開面板」。
- 活動時段的切法：真事件（statusline 不算）延長當前段（`SessionStore.swift:73-74`）；跟上一個事件相隔 10 分鐘以上就收段、開新段（`Sources/CubiKit/SessionInfo.swift:51-59`）；沉默 10 分鐘也收段，結束點是最後一個事件，不含閒置尾巴（`SessionStore.swift:257`）；SessionEnd 收段（`SessionStore.swift:159`）；點機器人叫醒不算事件（`SessionStore.swift:219-220`）。這 10 分鐘是固定的，跟設定頁「多久沒動靜進入沉睡」無關（那個只管表情）（`SessionStore.swift:23`）；改成固定值之前記下的時段照原樣，不重算。

## tick hook（experimental）

stdin（`hook-io.schema.json#/$defs/tickInput`，`PluginIO.swift:50-57`）：`{"now": <epoch 秒>, "sessions": [<同上的 session 物件>…]}`。帶的是所有活著的 session；剛結束或放生的那一次也會帶到，讓最後一段能送出（`SessionCoordinator+Plugins.swift:12-31`）。同一個 session 立刻 `--resume` 回來時，那一次可能同 id 出現兩筆，以 id 合併即可。`segments` 只帶 48 小時內的（`SessionCoordinator+Plugins.swift:20`）。

stdout（`hook-io.schema.json#/$defs/tickOutput`）：

```json
{"calendar":[{"title":"PROJ-12 範例工單","start":1762218720,"end":1762228000,"notes":"https://jira.example/browse/PROJ-12","marker":"sprint:3d221898:1762218720"}]}
```

- `calendar[]`（最多 50 筆，多的不收）：要出現在行事曆上的事件（`PluginIO.swift:14`、`:184-198`）。`marker`（`[A-Za-z0-9:._-]{1,80}`）是這筆的穩定識別，Cubi 埋在事件備註最後一行 `由 Cubi 記錄 · <marker>…`（`Sources/CubiKit/CalendarMerge.swift:12`）。同一個 marker 再送：時間變長就延長那筆事件，碰到旁邊自己的事件也併進去，都沒變就略過。所以**每次 tick 把該在行事曆上的東西全部重送就對了**。
- 單筆要 start < end、不超過 24 小時、start 在現在前後一年內（毫秒誤當秒會被擋），不合規的那筆單獨略過（log 列原因），其他照寫（`PluginIO.swift:169-179`）；不到 60 秒的不寫（`CalendarMerge.swift:11`、`:34`）。
- 同標題、前後 5 分鐘內的事件合成一筆（延長既有事件、刪掉多的，備註與記號合併，使用者自己加的備註行保留）。只併 Cubi 自己寫的，別人手動建的不碰（`CalendarMerge.swift`）。
- 事件標「空閒」（`Sources/cubi/Calendar/SystemCalendar.swift:115`）。EventKit 設不了「私人」，那本行事曆別分享給人。
- 行事曆沒授權或沒選（設定頁「行事曆」）時整批略過；log 每 10 分鐘提醒一次（`PluginTicker.swift:16`、`:67-70`）。
- 其他 tick 失敗（exit 非 0、逾時、輸出不合規）只進 log，同一類 10 分鐘一次。

## 背景服務（`service`，experimental）

套件開著、而且使用者打開它的「背景服務」開關（預設關）時，Cubi 啟動 `service.run` 並一直看管它；開關或套件關掉、重新載入後 `service` 變了、Cubi 結束時讓它結束。設定頁在開關旁顯示狀態：執行中、幾秒後重新啟動、一啟動就結束（黃）、不再重新啟動（紅），黃、紅會附上它 stderr 的最後一行（`Sources/cubi/Plugins/PluginServices.swift:48`、`:160-198`、`Sources/cubi/Settings/PluginsSection.swift`）。

**怎麼啟動**（`ServiceProcess.swift`）：
- 不經 shell，在套件資料夾裡，環境跟命令一樣多一個 `CUBI_BIN`（`ServiceProcess.swift:76`、`PluginServices.swift:83`）。
- 它自己承擔權限：macOS 的區域網路、輔助使用等權限算它的，不是 Cubi 的。用的是 libsystem 的 `responsibility_spawnattrs_setdisclaim`（不是公開 API）；這個 macOS 沒有它時就不啟動並顯示紅字，不會改用 Cubi 的權限跑（`ServiceProcess.swift:55`）。權限詢問視窗與系統設定上顯示的名字，還沒在真機確認。
- 所有訊號回到預設、沒有遮罩（Cubi 自己忽略 SIGPIPE，忽略的訊號會被繼承），自成一個行程群組，除了 stdin、stdout、stderr 拿不到 Cubi 的其他檔案（`ServiceProcess.swift:68`）。

**對話**（`ServiceProtocol.swift`）：一行一個 JSON 物件。
- Cubi 的第一行是 `{"protocol":1,"type":"hello"}`（`ServiceProtocol.swift:98`、`PluginServices.swift:100`）。服務在收到這一行之前不該做任何事；沒收到、或 `protocol` 不是它認得的數字就結束。這樣從面板、hook 或終端機直接執行它都不會動作。
- 服務的 stdout：每行最多 16384 bytes，超過整行丟；每秒最多 10 行（`ServiceProtocol.swift:12-15`、`PluginServices.swift:135`）。`type` 是 `service.events` 沒列的、或欄位不合規則的，丟掉並寫一行 log（每分鐘最多 5 行）。
- Cubi 寫給服務的訊息不會等它讀：它沒讀的累積超過 65536 bytes，新的那則就丟掉並寫一行 log；一則訊息不會只送一半（`ServiceProcess.swift:137`、`PluginServices.swift:145-147`）。

| type | 欄位 | 這一版 Cubi 怎麼處理 |
|---|---|---|
| `log` | `text`：1–200 字 | 寫進 cubi.log，每分鐘最多 20 行（`PluginServices.swift:139`） |
| `state` | `data`：物件 | 留著；之後的版本給面板讀（`PluginServices.swift:141`） |
| `notice` | `title` 1–40 字，`body` 選填 1–120 字，`sound` 選填 `knock`／`zap`／`thud` | 目前只寫進 log；島上顯示在之後的版本（`PluginServices.swift:148`） |
| `present` | `id` 0 以上整數，`effect` 是 `knock`／`zap`／`shake`，`from` 1–40 字，`windowShaken` 選填 | 目前一律回 `{"id":…,"ok":false,"reason":"unavailable","type":"presented"}`；浮層在之後的版本（`PluginServices.swift:143`） |
| `reply` | `id`、`ok`、`out` 任意 JSON | 目前沒有對應的 `call`，略過（`PluginServices.swift:150`）。之後 `out` 會原樣交給面板 |

文字欄位不能有控制字元、換行（含 U+2028、U+2029）、文字方向控制字元，不能只有空白；以字算長度，另外最多是上限 ×4 個 Unicode 字元（`ServiceProtocol.swift` 的 `optionalText`）。

**結束**：
- Cubi 要它停時先關它的 stdin（服務讀到 EOF 就該結束），2 秒後對整個群組送 SIGTERM，再 2 秒送 SIGKILL；Cubi 結束時改成立刻送 SIGTERM、1 秒後 SIGKILL（`ServiceProcess.swift:187-214`）。這種結束不論怎麼結束都不算失敗，不重新啟動、不計入次數（`ServiceSupervision.swift:46`、`PluginServices.swift:171`）。
- 它自己結束時，它啟動的其他程式（同一個群組）一起被結束（`ServiceProcess.swift:118`）。
- 以 0 結束：不重新啟動；啟動後 10 秒內就以 0 結束的顯示黃字。其他結束：`restart: on-failure` 時 1、2、4、8 秒後重新啟動，10 分鐘內第 5 次就停下來顯示紅字，要使用者關掉再打開開關才會再試；`never` 直接紅字（`ServiceSupervision.swift:20-55`、`PluginServices.swift:171`）。
- 它的 stderr 只留最後 8192 bytes，顯示最後一行時控制字元改成 `\u{…}`、最多 200 字（`ServiceSupervision.swift:64-78`）。

## 受限 session（`session.new`，experimental）

`session.new` 把一段文字交給一個 agent，所以 manifest 要先寫 `"builtins": ["session.new"]`，而且每次都會跳確認框列出目錄與第一句話（`ToolPanel.swift:162-190`）。目錄要存在，prompt 選填；失敗回 `{ok:false, err}`，取消回 `{ok:false, cancelled:true}`。

欄位只有五個，其他一律拒絕，不能傳旗標、指令或規則（`Sources/CubiKit/SessionNewSpec.swift:14-16`）：

- `directory`、`prompt`
- `restricted`：JSON 布林。
- `readDirs`：目錄路徑陣列，最多 8 個，每個都要是存在的目錄。根目錄、家目錄（或它的上層），以及家目錄下放金鑰與憑證的資料夾如 `.ssh`、`.aws`、`.gnupg`（或它們的裡面與上層）會被拒，`directory` 本身也一樣；比對的是資料夾本身，大小寫、符號連結、`/System/Volumes/Data/…` 的寫法繞不過（`Sources/CubiKit/DirectoryGuard.swift`）。
- `allowActions`：動作名稱陣列，最多 4 個，只能是這個套件標了 `"sessionAllowed": true` 的命令。

後兩個只能跟 `restricted: true` 一起用。

第一句話指向別人寫的文字（工單內容、外部文件）時請帶 `restricted: true`。Cubi 用 Claude Code 的受限模式開 session，而且**完全不問人**：`claude --restricted --permission-mode dontAsk --strict-mcp-config --disable-slash-commands --tools 'Read,Grep,Glob,Bash' --settings … --add-dir … --allowedTools …`（旗標寫死在 `Sources/CubiKit/SessionLaunch.swift:76-79`；`--restricted` 需要 Claude Code 2.1.248 以上；以下行為對 2.1.322 實測，本次文件整理沒有重測）：

- 使用者自己的允許規則、MCP、skills 與自訂指令都不套用。需要詢問的呼叫一律自動拒絕，沒有任何提示可按。
  - 不用逐條詢問的模式，原因：那個模式在每個提示上都有「允許並切到 accept edits」，選了之後檔案指令就不再問，而且沒有設定能拿掉它。
- 能執行的只有 `allowActions` 列的動作，而且只有 `<這個 Cubi 的完整路徑> --tool-run <套件 id> <動作> <參數>` 這一種寫法。
  - 放行規則是 `Bash(<cubi> --tool-run <id> <action>:*)`（`SessionLaunch.swift:50-53`）。
  - 前面加 `cd … &&`、後面接 `&&`、`;`、`|`，或用 here-document 餵參數，整條都會被拒。所以給 session 的說明要把完整指令印好：路徑用環境變數 `CUBI_BIN`，參數放單引號裡，文字裡的單引號寫成 `'\''`。
  - 動作後面接的每個字，cubi 都當成那個動作的參數，旗標也一樣，不會切到別的模式（`Sources/CubiKit/CubiCommand.swift:28-31`），參數數量或型別不符就拒絕。
- Claude Code 內建不問的唯讀指令（`ls`、`cat`、`grep`、`head`）仍然能跑，但讀不到工作目錄與 `readDirs` 以外的檔。
- 確認框寫明是受限模式、不會問、能執行哪些動作、另外能讀哪些資料夾。
- **`readDirs` 不受使用者拒絕規則保護**：拒絕規則大多寫成 `**/.env` 這種相對工作目錄的樣式，蓋不到 `--add-dir` 的資料夾。所以 `readDirs` 只能指向專門放要給 session 看的檔的資料夾（sprint 用它資料目錄底下的 `briefs/`）。這一條是推論，沒有用 Claude Code 實測過。
- 路徑以連續的點結尾之類、Claude Code 覺得可疑的資料夾，讀取一定要人核准，在不問的模式下等於讀不到。工作目錄與 `readDirs` 都要避開。
- Cubi 執行檔的路徑有英數、`/`、`.`、`_`、`-` 以外的字元時，帶 `allowActions` 的受限 session 不開，訊息會說是安裝路徑（`SessionLaunch.swift:57`、`ToolPanel.swift:199-206`）。
- 受限模式不讀使用者的設定檔，Cubi 的 hooks 也跟著不見。所以每次開受限 session 前，Cubi 把以下內容寫到 `~/.cubi/restricted-settings.json`，用 `--settings` 帶進去（`Sources/cubi/HookSetup.swift:59`、`Sources/CubiKit/ClaudeHookInstaller.swift:162-163`）：
  - Cubi 的 hooks。
  - 你的拒絕規則：`~/.claude/settings.json`、工作目錄的 `.claude/settings.json` 與 `.claude/settings.local.json` 三份的 `permissions.deny` 合併；允許規則與其他設定一律不帶。
  - 固定寫上 `disableAutoMode`、`disableBypassPermissionsMode`（按 shift+tab 切不到那兩種模式）與 `blockReadsOutsideWorkingDirectories`。
- 合併拒絕規則的細節：
  - 檔案類工具（Read、Edit、Write、MultiEdit、NotebookEdit、Glob、Grep）規則裡單一斜線開頭的路徑會改寫：那種寫法是從規則所在的設定檔算起的，原樣搬到 `~/.cubi/` 會指到別處而失效。所以使用者層的 `/x` 寫成 `~/.claude/x`，專案與本機層的寫成 `//<工作目錄>/x`。其他寫法與其他工具的規則不動。
  - 讀哪幾份跟 Claude Code 一樣：專案層只看工作目錄本身的 `.claude/settings.json`（不往上找）；本機層在 git repo 裡讀 repo 根目錄的 `.claude/settings.local.json`，不在 repo 裡才讀工作目錄的。
  - Claude Code 在檔案擁有者檢查不過時不讀本機層，Cubi 沒有做這個檢查；那種情況會多帶一份拒絕規則，只會更嚴。
  - 任何一份讀不了就不開 session。
  - 這個檔只有一份、每次受限啟動前重寫，所以不要在一兩秒內從不同目錄接連開兩個受限 session。
  - 解除安裝 Cubi 的 hooks 時刪掉這個檔（`HookSetup.swift:88-90`）。沒安裝 Cubi hooks 時這個檔照寫照帶，只是裡面沒有 hooks（瀏海上就看不到這個 session）。
- 終端那一行太長時（超過約 900 位元組），Cubi 把指令寫進 `~/.cubi/launch/<隨機名>.sh`，終端裡只打一行 `source '…'`（`SessionLaunch.swift:96-98`、`:104-107`、`Sources/cubi/SessionLauncher.swift:57`）。
  - 原因：macOS 的終端在 shell 還沒準備好時，一行最多收 1024 位元組。
  - 那個資料夾只有你進得去，超過一小時的舊檔下一次啟動時清掉。
  - 所以受限 session 的分頁上看到的是這行 `source`；完整指令在那個檔，以及 log 的 launch 那行（寫了位元組數與檔名）。
- 受限模式管不到的：終端的環境變數、`~/.claude.json` 裡的狀態、工作目錄與家目錄的 `CLAUDE.md`，這些 session 照用。
- 受限 session 不會跳審批卡；relay 仍會標記它是受限的，萬一有卡，卡上也不給「總是允許」。

## agent 套件（實驗中，不承諾相容）

整章 experimental，目前沒有真實使用者。範例：`docs/plugins/example-agent/manifest.json`；載入在 `Sources/CubiKit/ManifestPlugin.swift`。

| 欄位 | 必填 | 說明 | 穩定度 | 出處 |
|---|---|---|---|---|
| `id` | ✔ | `[a-z0-9-]`，最多 24 字，等於資料夾名；也是 relay 的 `--agent` 值與 socket 信封的 `agent` | experimental | `ManifestPlugin.swift:48-49` |
| `name` | ✔ | 設定頁顯示名 | experimental | `ManifestPlugin.swift:50` |
| `color` | | `#RRGGBB`，沒給或不合規用灰 | experimental | `ManifestPlugin.swift:106` |
| `capabilities` | | 只有 `statusline` 有作用。`approvals`、`questions` 會被忽略：manifest 沒有回覆模板，審批與問題不會上島 | experimental | `ManifestPlugin.swift:53-58` |
| `secrets[]` | | `{key, label, required}`；值存登入鑰匙圈，不進 manifest；沒有 `key` 的那筆略過 | experimental | `ManifestPlugin.swift:60-63` |
| `install.mode` | | `json-hooks` 或 `manual`（預設）；其他值拒載。`manual` 時 `install.instructions` 顯示給使用者自己貼 | experimental | `ManifestPlugin.swift:68-94` |
| `install.file` | json-hooks 必填 | 要寫的 JSON 檔，可用 `~`；格式比照 Claude Code 的 `hooks.<event>[] = { hooks: [{type, command, timeout}] }` | experimental | `ManifestPlugin.swift:70` |
| `install.entries[]` | | `{event, command, timeout}`。`command` 必須含 `cubi-hook --agent <id> `（尾端空白），安裝狀態與解除靠它認出自己的條目，沒有就拒載。`timeout` 是 1–600 的整數秒，不寫是 10 | experimental | `ManifestPlugin.swift:72-89`、`:38` |
| `events.<native>.canonical` | ✔ | `sessionStart`、`prompt`、`toolStart`、`toolEnd`、`permissionRequest`、`question`、`notification`、`stop`、`sessionEnd`；沒寫或寫別的就拒載 | experimental | `ManifestPlugin.swift:34`、`:96-100` |
| `events.<native>.map` | | canonical 欄位 → JSON path（只支援 `$.a.b` 物件走訪，沒有陣列索引）；沒對映的用 Claude Code 的預設路徑 | experimental | `ManifestPlugin.swift:36`、`:179-187` |

`map` 可用的欄位（括號是預設路徑）：

| 欄位 | 用於 | 預設 |
|---|---|---|
| `session` | 全部，必要 | `$.session_id` |
| `cwd`、`transcript` | 全部 | `$.cwd`、`$.transcript_path` |
| `tool` | toolStart、toolEnd、permissionRequest | `$.tool_name` |
| `input` | toolStart、toolEnd、permissionRequest、question | `$.tool_input` |
| `toolUseID` | 全部 | `$.tool_use_id` |
| `ok`、`response` | toolEnd | `$.ok`、`$.tool_response` |
| `source` | sessionStart | `$.source` |
| `prompt` | prompt | `$.prompt` |
| `type`、`message` | notification | `$.notification_type`、`$.message` |
| `message` | stop | `$.last_assistant_message` |
| `reason` | sessionEnd | `$.reason` |

行為：

- 未知 `agent` 的信封直接丟棄；套件關閉時不裝 hooks、不顯示、不解碼。
- 解除安裝只刪 `command` 含自己 tag 的 group，其他套件與使用者自己的 hooks 不動（`ClaudeHookInstaller.swift:51-57`）。
- blocking 事件（`permissionRequest`、`question`）decode 出來後，套件沒有對應能力時，app 不開卡片、不出聲，直接關連線讓 agent 用自己的提示；機器人當成 `toolStart` 顯示 working（`Sources/cubi/SessionCoordinator.swift:196-199`）。manifest 套件一律如此（`ManifestPlugin.swift:141`）。

## 檔案佈局與安裝

- 整個套件資料夾複製到 `plugins/<id>/` 就能用（`panel.file` 用相對路徑、`run` 用 `$plugin/…`）。從原始碼裝內建範例：`scripts/install-plugin.sh docs/plugins/sprint`（複製時排除 `tests`、`__pycache__`）。
- 套件自己的資料別放在 `plugins/<id>/` 裡（重裝會被覆蓋），放 `~/Library/Application Support/cubi/<id>/` 之類。

## 命令列

`cubi` 只看第一個參數決定做什麼（`CubiCommand.swift:15-17`），完整清單在 [advanced.md](../advanced.md) 的「命令列」。

除了 `--validate-plugin`（直接給資料夾），下面的指令都只到 `$HOME/Library/Application Support/cubi/plugins/<id>/` 找套件（`PluginRegistry.swift:13-14`、`:42`），而且會真的執行套件的指令。要在不動真資料的情況下試，就把 HOME 換成暫時的資料夾、把套件複製進去，指令範例在 [guide.md](guide.md#7-打開面板)。換了 HOME，腳本用 `~` 組的路徑會跟著換，寫死的絕對路徑與環境變數指到的地方不會。

跟套件有關的指令：

| 指令 | 說明 | 穩定度 | 出處 |
|---|---|---|---|
| `cubi --validate-plugin <資料夾>` | 見「載入規則」 | stable | `main.swift:25-38` |
| `cubi --render-panel <id> <out.png> [--dark] [--height N] [--eval JS]` | 在螢幕外開真的面板（真的 web view 與 bridge）截圖，設定頁關掉的套件不畫。沒有 `--eval` 時約 4 秒後截圖；有的話 JS 在約 4 秒時執行，結果印成 `eval → …`，再 2 秒截圖。結果是 Promise 時印 `eval → nil error: … unsupported type`，無害，非同步的部分照樣跑完、截圖看得到（實測）。環境多一個 `CUBI_RENDER=1` | experimental | `main.swift:65-89`、`ToolPanel.swift:84-88`、`:278-298` |
| `cubi --render-widget <id> <session 名> <out.png>` | 用一個假 session（id `render-widget`、沒有 cwd、沒有時段）跑 `session.info`，畫出資訊窗的列（不含底部按鈕）。環境多一個 `CUBI_RENDER=1` | experimental | `main.swift:93-105`、`SessionWidgetView.swift:100` |
| `cubi --tool-run <id> <action> [args…]` | 走套件的檢查執行一條指令，印 `{ok,out,err}`；參數寫 `-` 從 stdin 讀。跟面板有三處不同：`reveal` 只印路徑、不在 Finder 選取；沒有時限；執行與拒絕不寫 log。找不到套件時印出它被拒載的原因。`text` 參數也可以直接寫在命令列，寫 `-` 才從 stdin 讀。stderr 會多一行 `plugins: …` 的 log，可以忽略 | stable | `main.swift:212-240` |
