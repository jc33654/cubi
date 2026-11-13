# cubi 狀態與進度（2026-11-11）

commit 數與測試數以 `git log` 與 `make test` 為準，這裡不抄數字。Sources 約 6,000 多行 Swift。

## 已完成

| 區塊 | 內容 | 狀態 |
|---|---|---|
| Relay `cubi-hook` | Darwin-only，stdin → unix socket → stdout；blocking 事件等回覆 115 s；statusline 串接（原指令 shell-quote 成單一參數）；`--capture` 錄 payload | 真機驗證 |
| 事件模型 CubiKit | canonical events、`SessionStore` reducer、回覆編碼（allow / always / deny / 問題答案）、`EditSummary` diff、`TranscriptWatcher`、安裝器（備份、diff、CAS 寫入、依 `--agent <id> ` 辨識自己的 hooks） | 單元測試 |
| 島（瀏海） | hidden / compact / expanded；機器人列隨數量變寬並以瀏海為中心（compact 與 expanded 都是整個島往左挪，排比 640 寬才加寬；之前 expanded 置中，五隻以上第一隻被切）；expanded 高度隨內容、有資訊面板時 860 寬；右鍵 app 選單 | 真機驗證；多隻版面離線渲染 4／5／6／8 隻＋Jade 真機五隻展開驗證（2026-11-03） |
| 浮動視窗 | 拖離瀏海即浮動，可放任何螢幕；位置記島頂中心；拔螢幕夾回；拖回頂端 dock；選單切換 | 真機驗證（外接螢幕） |
| 機器人 | 8 種狀態（含 tired）；每 session 一色；右鍵換形狀（方塊／圓／三角／六角）與顏色，記住（UserDefaults `sessionLooks`，200 上限）；翼上拖曳排順序，清單同序，記住（`sessionOrder`） | 單元測試（順序、looks 淘汰、JSON 往返）；載回路徑真機 log；拖曳與重啟後外觀待 Jade 親手試 |
| 審批／問題卡片 | 拒絕／在終端處理／總是允許／允許；AskUserQuestion 選項卡；終端先答或 Esc 自動撤卡；只認同一 tool call 的事件 | 真機驗證 |
| Session 資訊面板 | 專案、模型／effort／版本、開始時間（transcript 建立時間）、使用時間、回合與工具呼叫數、花費、變更行數、context、終端、跳到終端 | 離線渲染驗證；點列待 Jade 親手試 |
| 工作中／晚安／放生 | 沉睡 12 小時（可調）自動進晚安區；右鍵「去睡覺」「起床上班」「放生」；放生後只有送訊息、被問、SessionStart 會回來；兩個集合存 UserDefaults | 放生與拉回真機以 fixture 重播驗證；右鍵待 Jade 親手試 |
| 開新 session | 右鍵「開新 session…」對話框（最近專案／瀏覽、第一句話、接續、終端）、機器人右鍵「再開一個」「在新分頁接續這個 session」（`--resume <id>`）、右翼用量旁的 ＋（compact 就能按）；Ghostty 走 AppleScript `new surface configuration` + `input text`（不用 `initial input`，見已知限制），Terminal.app 走 `do script`；`cubi --new-session` CLI 同一條路 | CLI 真機驗證（Ghostty 帶第一句話 → 4 秒內 SessionStart + prompt；Terminal.app `--continue` → 接到同一個 session；`--resume <id>` 真機驗證；終端開不了時的警告路徑沒驗）；對話框與右鍵待 Jade 親手試 |
| 用量 | 5h / 7d / cost 跨 session 合併，最近活動的 session 才能覆寫 | 真機驗證 |
| 聚焦終端 | Terminal.app（tty）、Ghostty（標題／cwd）、Claude app 裡的 session 走 `claude://code/continue?session=local_…`（對照表 `~/Library/Application Support/Claude/claude-code-sessions/*/*/local_*.json` 的 `cliSessionId`，沒對到只切 app）、其他 app 只切 app；沒有終端身分時用名稱／cwd 猜 Ghostty 再 Terminal.app；點沉睡的機器人會叫醒 | 有身分路徑真機驗證；Claude app 連結真機驗證過（`open` 那條連結，目標 session 的 `lastFocusedAt` 更新、其他不動），Cubi 內點擊待 Jade 親手試；猜測路徑只有腳本語法驗證 |
| 安裝器 UI | 設定頁：Claude Code hooks 安裝／解除（看 diff 再寫）、退役舊 notify hook、Agents 開關與 API key、顯示（保持顯示、滑入就展開、機器人大小 28／36／44）、睡眠（沉睡 5–60 分鐘、晚安 1–24 小時或從不；改了立刻 tick：調短立刻生效，調長只有自動進晚安區的會回來、已沉睡的不叫醒）、範圍、插件（Agents／工具） | 真機驗證；三個新設定 Jade 真機驗證（2026-11-03：關滑入展開、切大小後拖曳、沉睡 5 分鐘） |
| Plugin 架構 | `AgentPlugin` 協定；`ClaudeCodePlugin` 內建；`ManifestPlugin` 以 JSON 接新 agent（只能監看） | 單元測試＋假 manifest 真機 |
| 工具插件 | `kind: tool` manifest：HTML 面板 + 白名單指令表（`ToolPlugin` 解析／型別驗證、`ToolPanel` 執行不經 shell、bridge 名可設）；選單與設定頁入口；`cubi --tool-run`；原本寫死在 app 裡的那個管理面板改成 Jade 本機的私用插件（manifest 放 plugins/，不進 repo） | 6 個單元測試；真機 `--tool-run`：私用插件的 status／asset.read 走通、`../x` 與未宣告 action 被擋；面板點擊待 Jade 親手試 |
| session 掛件 | 工具插件選填 `session{info,refresh}`：資訊窗選到 session 時 cubi 把 session（含活動時段）餵 stdin、畫它回的列（可帶連結）與按鈕，「開面板」把 session 注入面板；`$plugin`、相對執行檔、工作目錄＝插件目錄；hook 命令 20 秒逾時（殺整個 process group） | 單元測試（manifest 驗證、PluginIO 上限）；CLI 餵 stdin 走通；真機畫面待 Jade |
| 活動時段 | `SessionInfo.segments`：真事件開段／依 sleepAfter 切段、tick 收段、SessionEnd 收段、叫醒不算；結束／放生的最後一段保留到下一次 tick | 單元測試 |
| 第三輪 dashboard（2026-11-05） | 資訊窗：列的 `tone`／`progress`／`clock`、按鈕 `icon`；sprint 的 ▶／⏸ 計時與估點倒數。面板：樣式包 `panel.style:"cubi"`、sprint 面板 dashboard、草稿機制（打到一半不丟、組字中不重畫、亂序回應）。設定頁：左側導覽＋卡片、淺深兩套、`--render-settings` | 單元測試（PluginIO、sprint 35 個）；`--render-panel --eval` 探針（草稿 20 多個情境）；`--render-settings` 六頁 × 淺深；渲染前後 defaults 不變；點按互動待 Jade |
| 行事曆 | 工具插件選填 `tick{action,every}`：定時餵所有 session，回的 calendar 條目由 `SystemCalendar`（EventKit）寫進設定頁選的行事曆；記號去重、同記號延長、同標題 5 分鐘內合併、每筆 commit、標「空閒」；設定頁「行事曆」區 | `CalendarMerge` 純函式測試；EventKit 真機授權與事件待 Jade |
| sprint 插件 | `docs/plugins/sprint/`：Python 標準庫；Jira 用 netrc；sprint＝標籤（這個 Jira 沒有 Sprint 欄位）；多專案 JQL（預設只抓受託人是自己的）；自動／手動綁單（資訊窗可直接綁／解除）、多單比例分攤、手動時段、transition；▶／⏸ 計時（停下時依當下綁的單分）、面板「綁定總覽」（只列本 sprint 有活動的 session）、資訊窗最多列 8 張；實際點數＝投入時數÷每點小時數（預設 8，不能手動改，可設欄位寫回），「投入」點開看各類工時與每筆手動時段的備註；「沒有單號的工作」（可選計入工時、寫行事曆，不扣容量）；★ 重點標記可排序；狀態色照 Jira 狀態分類；`CUBI_RENDER` 離線渲染乾跑（不存檔、不連 Jira）；回顧：五卡、任務分類甜甜圈（提早／準時、超時完成、未完成、超時未完成、未估點，點開列單）、burndown、近幾個 sprint、總結＋四段＋感謝、Markdown 匯出；「用 Claude 整理回顧」寫數據檔並開 Claude Code session（內建 `session.new`）寫好後填回 | `make plugin-test`（unittest）；CLI 對真 Jira：`session.info`／綁單號 input／`sprint.sync {replace}`（新 JQL 抓到 25 張受託人是 Jade 的單）／`review.brief` 產檔走通；面板畫面待 Jade |
| 發佈 | `make bundle` strip debug 符號並守門（執行檔裡不得有 `/Users/…`）；`make dist` 產固定檔名 `Cubi.zip`；`scripts/install.sh` 下載、sha256 完整性校驗、`codesign -R` 比對 cubi-dev 憑證 hash 後才裝並拿掉 quarantine；`ci.yml`／`release.yml`（tag 觸發，從 secrets 匯入 .p12 簽） | 真機驗證：v0.1.0 由 release.yml 在 macos-26 建、簽、掛上 Release（1.5 分鐘）；從 `releases/latest/download/` 抓回來 sha256 與 `codesign -R` 都過、OSO 0、版本 0.1.0 |
| 文件 | README（介紹、機器人表情與島的截圖 `docs/images/`、安裝、操作一覽、解除）、`docs/development.md`（make 目標、CLI、憑證、發版、設計上刻意的事）、`docs/protocol.md`（relay 協定、欄位、manifest 格式）、`docs/plan.md` | 經審查員對帳；圖是 `--render-island` 渲染後裁的 |

舊工具退役：`私用 CLI menubar` 已停並取消登入啟動、`私用 CLI notify off`、`notify-hook.sh` 從 settings.json 移除；保留 `statusline.sh`、`私用 CLI`、`zh-reply-guard.py`。

## 待 Jade 親手驗證

1. 右鍵機器人（翼上或清單列）換形狀／顏色；島空白處右鍵仍是 app 選單。
2. 拖島離開瀏海成浮動視窗、拖回頂端 dock。
3. 點清單列開資訊面板、「跳到終端」、✕ 關閉；看面板哪些列有出現（判斷 2.1.312 實際送了哪些 `cost.*` 欄位）。
4. 右鍵「去睡覺」→ 翼上消失、出現「💤 1」、清單在晚安區；「放生」→ 消失；在那個 session 送一句話 → 回來。
5. 翼上拖一隻機器人換順序 → 清單同序；重啟 Cubi 順序還在；拖機器人時島不會變浮動；右鍵改形狀／顏色後重啟還在。
6. 右鍵「開新 session…」：對話框選專案、填第一句話（含繁中）、開始 → 終端開新分頁、島上出現新機器人；機器人右鍵「在新分頁接續這個 session」。（Jade 已驗：對話框與繁中第一句話 OK）
7. 點改過名的那隻（同目錄還有別的 session 時）→ 跳到它自己的分頁；改名後一分鐘內機器人名字跟著變。
8. 右鍵選單開私用面板走一輪（status、開關、編輯寫入、reveal、pick），行為應與之前一樣。
9. 在另一台沒裝過的機器跑 `curl -fsSL https://raw.githubusercontent.com/jc33654/cubi/main/scripts/install.sh | bash`，看 Automation 授權與機器人是否出現（v0.1.0 已發，secrets 已設）。
10. 資訊窗：選一個名字帶單號的 session，底下有「Sprint · Sprint6」區塊，單號列可點開瀏覽器，「同步 Jira」「開面板」有反應；example-tool 的區塊也在。
11. 設定頁「行事曆」：允許存取 → 選一本行事曆；一分鐘後綁了單的 session 收掉的段出現在行事曆（標題＝單號＋session 名、標空閒、備註最後一行有記號）；重啟 Cubi 不重複；前後 5 分鐘內的段合成一筆。
12. Sprint 面板：Sprint6 已用新 JQL 重抓（25 張受託人是你的單，沒填起訖）——填起訖日期、看「投入」欄的點數、點開各類工時明細、+時數一筆會議勾行事曆、換一個狀態（會真的送 Jira）、回顧分頁點甜甜圈的一類看單、匯出 Markdown 到 Finder。
13. 資訊窗 Sprint 區塊：「綁單號…」跳輸入框、打 `PROJ-xxxx` 綁上；每列尾端的 ✕ 拿掉那張單；沒有 Example Tool 區塊了。
14. 回顧分頁「用 Claude 整理回顧」：先跳確認框（目錄與第一句話）→ 在設定的資料夾開一個 Claude Code 分頁、第一句話叫它讀 `<reviewDir>/Sprint6-data.md`；它跑 `cubi --tool-run sprint review.update -` 時在終端批准；面板每 30 秒查一次，寫好就出現。
15. 浮動視窗拖到外接螢幕：島應跟著過去（拖的時候視窗縮成島大小），放開後再拖回瀏海能 dock。
16. 右鍵選單沒有「Demo 狀態」了。
17. 資訊窗（第三輪）：按鈕是 icon、滑上去有說明；狀態色（工作中藍、思考紫、等你橘、錯誤紅）；Sprint 區塊 ▶ 開始計時 → 「計時中」每秒走、剩餘跟著倒數 → ⏸ 停止 → 面板「手動時段」多一筆「計時」、行事曆一筆、不跟自動段重疊。
18. Sprint 面板（第三輪）：「總覽／回顧／設定」左側導覽；「＋時數」在單底下展開、打到一半切分頁不丟；用注音在回顧欄位打字時，面板 30 秒輪詢不會打斷組字。
19. 設定頁（第三輪）：左側導覽六頁、淺色與深色各看一次；開關與主按鈕是藍色（離線渲染畫不出）；插件頁切一個工具的開關 → 畫面立刻變、「開啟」鈕跟著停用；行事曆頁顯示你實際的權限狀態。在插件頁替一個 agent 按「安裝…」寫入後，卡片按鈕立刻變「更新…／解除…」；設定視窗關掉再開、或切頁，上一次的「已安裝」訊息不再出現。系統通知：第一次打開時在詢問框按「不允許」→ 開關旁出現「沒有權限」；按「打開系統設定」看實際開到哪一頁（目標是通知設定）；在系統設定改成允許後切回 Cubi，標籤消失。
20. 第三輪之後（11-06）：Sprint 總覽「待處理點數」紅字與「排了 X / 容量 Y 點」；session 清單列與資訊窗不再把「思考中」寫兩次（清單離線畫不出，沒驗）；設定窗左上角的方塊 Cubiii 眼睛跟著滑鼠、改任何設定會開心一下、切到別的 app 時停住（都沒驗）。工單表不撐出卡片、＋時數與換狀態按鈕看得到、換狀態的選單浮出來看得到選項；☆／★ 標記（重開面板還在）、點標題排序；對話框與面板裡 ⌘V 能貼上單號（也能貼整個 Jira 網址）；綁單號對話框、設定頁、面板裡各按一次 ⌘Z 能還原；⌘W 關設定窗與面板；點過島之後按 ⌘Q 不會關掉 Cubi（結束走選單列）；資訊窗解除按鈕（已改成每列尾端的 ✕，見第 22 條）。

21. 11-06 下午：sprint 設定頁與設定窗的 ⓘ 滑上去出現說明；滑上去再點 → 固定；固定後再點 ⓘ 本身 → 收起；點別處也收起（設定窗那邊離線畫不出，沒驗）；工單表「★」標題能排序、沒排序時有星號不再自動置頂；「投入」顯示點數、點一下展開各類工時，上方「投入」數字卡點一下展開整個 sprint 的；「實」欄不見了；「寫回 Jira」送的是這張單所有 sprint 的投入換算點數；「沒有單號的工作」記一筆（記在開始時間所在的 sprint；不寫說明會擋、取消勾「計入工時」不加進投入、勾行事曆會出現在行事曆）。
22. 資訊窗：綁 6 張單時每一列尾端都有 ✕，滑上去寫「解除 單號」，點了只拿掉那一張；底部不再有「✕ 單號」按鈕（離線畫過列，底部按鈕列與點擊沒驗）。Sprint 工單表點「投入」展開後，各類合計底下逐筆列出本 sprint 補過的時段與備註（分給多張單的寫出比例）。
23. 資訊窗綁超過 8 張單：只列 8 張（計時中時 7 張），下一列「還有 N 張沒列出」；面板總覽分頁「綁定總覽」只列這個 sprint 有活動的 session（上一期的不出現），展開後每個 session 一列、每張單有 ✕，解掉別的 session 的單也行；計時停下來時依當下綁的單分（計時中解掉一張再綁回來，照樣分到）；全解掉的話資訊窗「計時中」寫「單都解除了，停下來不會記」、按鈕與面板寫「不記」；投入明細裡 session 自動記的那類改叫「Session」。
24. Sprint 面板按一次「同步 Jira」：同樣是「進行中」的單都變藍（之前抓的單沒存狀態分類，畫成灰）；手動加、JQL 查不到的單也會跟著更新。
25. 11-10：資訊窗「綁單號…」跳出的輸入框浮在島上面、切到別的 app 也不會消失、開著時 Cubi 其他東西照動；點下去能直接打字（不用再點一次輸入框）；用注音組字時按 Return 是選字、不會直接送出；開著時再按一次「綁單號…」換成新的那個。島上接續 session 開不了終端時，錯誤訊息也浮在島上面、按「好」收掉。Cubi 主執行緒真的卡死時（不是開著對話框；探針用 SIGSTOP 驗過），Spotlight 打「重開 Cubi」（`~/Applications/重開 Cubi.app`，`make install` 與 install.sh 都會產生；直接點 Cubi.app 不會開新程序）：心跳 3 秒沒動的那份被強制結束、換成新的；沒卡死時再開一次只會叫出島，開著選資料夾等對話框也不會被誤殺。看不到的視窗不在這個範圍內：島上叫出的輸入框與錯誤訊息、面板「用 Claude 整理回顧」開 session 前的確認框都已改成浮在島上面的面板，剩系統的選資料夾視窗（從前景視窗開）。確認框：要用滑鼠點「開啟」才開 session（Return 不算，Esc＝取消），取消或關掉回「已取消」；「要交給 Claude 的話」最多顯示 400 字並寫總字數；確認框開著時插件再要開 session 會被拒（「已有一個開 session 的確認在等你回答」），開著的框不變。心跳待驗：長時間閒置（App Nap）與睡眠剛喚醒時，再開一次 Cubi 不會誤殺健康的那份。
26. 11-11：點 Claude app 裡開的 session 的機器人（或資訊面板「跳到終端」），Claude app 到前景並切到那段對話，不是停在原本看的對話；剛開、app 還沒寫下紀錄的 session 點了只會切到 app（log 有 `focus Claude.app …: no live app record`）。
27. 11-11：Cubi 出現在 Dock 與 ⌘Tab（啟動後 policy 切 `.regular`；plist 仍是 LSUIElement，所以啟動本身不會把 Cubi 帶到前景）。點 Dock 圖示（或 Spotlight／Finder 再開 Cubi.app）且沒有開著的視窗時開設定頁（log `reopened with no window open: showing settings`）；已有設定頁或面板開著就只帶到前面；設定頁縮到 Dock 時點 Dock 會拉回來。⌘Tab 只切到 Cubi、不開設定頁（刻意：前景 app 結束時 macOS 會自己啟用上一個 app，用「啟用」當觸發會讓設定頁自己跳出來）。要看的反例：(a) `make run`／「重開 Cubi」啟動時**不該**自己跳設定頁；(b) Cubi 已是前景（剛 ⌘W 關掉設定頁）再點 Dock 要能開（推論：reopen 不看 active 與否）；(c) 設定頁開著時選單列變成 Cubi 的，⌘Q 仍不會結束 Cubi（主選單刻意沒有 ⌘Q，見 AppDelegate.mainMenu 註解；Dock 右鍵「結束」可以）。離線渲染（`--render-*`）自己設 `.prohibited`，不會冒出 Dock 圖示。
28. 11-12 Sprint 節奏（離線渲染看過「建下一期」表單、週五結束的提示、理想線週末持平；點擊與自動切換沒真機驗）：總覽標題旁「建下一期」→ 表單預填下一期標籤與週一到隔週日；在開始日之前建立 → 面板停在原本那期、下拉選單那一項寫「尚未開始」；到開始日那天（Cubi 開著，一分鐘內）自動切過去，之後手動切回舊期不會再被切走；把一期的日期改到跟別期重疊 → 被拒並寫出撞到哪一期；Sprint6 結束日是週五時面板提示一次改成 11-15，關掉面板再開不再提示；設定頁「節奏錨點」填非週一的日期會被拒。
29. 11-12 受限模式開 session（單元測試驗過指令字串、欄位拒絕、確認框文字；沒有真的開過終端）：Sprint 回顧分頁「用 Claude 整理回顧」→ 確認框標題寫「受限模式的 Claude Code session」，內文有受限說明、「另外可以讀：<回顧資料夾>」，最後一行寫島上的審批卡不會有「總是允許」、終端裡 Claude Code 自己的「一律允許」才會讓 session 不再問；按開啟後終端裡的指令帶 `--restricted`；session 讀得到資料檔（資料夾在工作目錄外也行）；它跑 `cubi --tool-run sprint review.update` 時跳審批卡、核准後回顧出現在面板；瀏海上有這個 session 的機器人，它的審批卡只有「拒絕／在終端處理／允許」；在工作目錄放一個 `.env`（你的設定拒絕讀它）請 session 讀 → 被拒；在工作目錄的 `.claude/settings.json` 加一條 `Read(/secrets/**)` 的拒絕規則，session 讀 `secrets/` 底下的檔 → 被拒；資料夾或目錄名含空白、繁中、emoji 時指令沒有斷掉（Ghostty 與 Terminal.app 各一次）。
30. 11-12 時數快速加與編輯（離線渲染點過：快速加 1.5 小時、展開進階、把一筆 90 分鐘改成 1 小時後出現行事曆提醒、計時時段的開始／種類／備註是灰的；真機沒驗）：工單那列按「＋」→ 只有時數一格與「進階」，填 1 按「加」→ 多一筆剛剛結束的 1 小時；按「進階」→ 出現開始時間、種類、備註、寫進行事曆；「手動時段」與「沒有單號的工作」每筆有「改」→ 改時數後投入與剩餘跟著變；改一筆有寫進行事曆的時段（縮短、移動、改種類）→ 右下角提醒行事曆要手動調整，單純加長不提醒；計時記下的時段只能改時數；打到一半切到「回顧」再切回來，填的東西還在；關掉面板再開就不在了（原本就這樣）。
31. 11-12 review 提醒（假資料用真 binary 跑過 tick、資訊窗與面板橫幅；行事曆實際寫入沒驗）：review 日當天行事曆上出現一筆「Sprint review」（預設 10:00–10:30），只有一筆、一小時後也沒有多一筆；把它拖到別的時間或刪掉，不會再長出來；資訊窗 Sprint 區塊第一列是「今天 review」；Sprint 面板總覽最上面有「今天是 review 日」與「產生回顧」，按了跳受限模式的確認框；「重新寫入行事曆」按下後一分鐘內事件再寫一次（舊的還在原時間就不會重複）；設定頁把 review 事件時間清空 → 不再寫事件，另外兩處提醒還在；匯出的 Markdown 第一段有「產生於 …」。另：「沒有單號的工作」的「記一筆」表單時數改成填小時。
32. 11-12 手動估點與寫回時數（離線渲染看過：估點那格可輸入、Jira 連不上時回到原值並顯示錯誤、設了實際時數欄位才有沙漏鈕；真的寫進 Jira 只用插件的 Jira 類別對一張測試單試過欄位可寫可清，沒有從面板按過）：拿一張測試用的單，在工單表「估」那格把數字改掉按 Enter → Jira 上的估點跟著變、面板的待處理點數跟著變；清空 → Jira 欄位變空、面板算未估點；填 0、-1、abc → 不送出並說原因；設定頁「實際時數欄位」填好後，工單那列出現沙漏鈕，按了 → Jira 的實際時數變成這張單的總投入小時（按兩次數字一樣）；沒有投入的單按了被拒；欄位清空後沙漏鈕消失。
33. 11-12 自動寫回時數（只有單元測試與離線渲染，沒有對真 Jira 跑過定時執行）：設定頁「實際時數欄位」填好、勾「自動寫回時數」→ 替測試用的單加一筆時數 → 一分鐘內 Jira 上的實際時數變成那張單的總投入小時，面板沒有「尚未寫回」的提示；把那筆時數改掉或刪掉 → 一分鐘內 Jira 跟著變（刪光變 0）；綁那張單的 session 停止計時 → 一樣；把 Wi-Fi 關掉再加一筆 → 總覽最上面出現「1 張時數尚未寫回」，網路回來後一分鐘內消失；關掉「自動寫回時數」再加時數 → Jira 不變。另：節奏錨點預設改成留空，要預填就在設定頁填某一期開始的週一。
34. 11-12 受限 session 一定要問（真機第一輪發現：平常權限模式是 auto 的人，受限 session 沒問就跑了寫回面板的那條指令；拒絕規則那部分真機通過）。改成指令多帶 `--permission-mode manual` 與 `--disable-slash-commands`，設定檔固定停用 auto 與 bypass 模式；審查員在非互動模式實跑過「帶這份設定時即使指定 auto 也被擋」，互動 session 還沒有實跑證據：回顧分頁「用 Claude 整理」→ 開啟 → session 要跑 `cubi --tool-run sprint review.update` 時島上跳審批卡（卡上沒有「總是允許」）、log 有 permissionRequest；按允許後回顧才填上。在那個 session 按 shift+tab 切不到 auto，審批提示上也沒有「允許並切到 auto」的選項。
35. 11-12 指令太長會卡在終端（真機第二輪發現：加了旗標後整串指令 1065 位元組，超過終端一行的 1024，分頁停在指令那行不執行；上一版是 1016）。改成超過 900 位元組就寫進 `~/.cubi/launch/` 的檔、終端只打一行 `source`。用與 Cubi 相同的 AppleScript 在 Ghostty 與 Terminal.app 各實測過：長的那行兩邊都卡住，`source` 那行兩邊都執行，目錄名含空白、繁中、emoji，第一句話含引號、`$HOME`、反引號，參數原樣收到（打進去的是一個只記錄參數的指令，不是 claude）。真機待驗：回顧分頁「用 Claude 整理」→ 開啟 → 新分頁上是一行 `source '~/.cubi/launch/….sh'`，Claude Code 有啟動並開始讀資料檔。
36. 11-12 受限 session 改成完全不問（真機第三輪：逐條詢問的模式會問、切不到 auto、拒絕規則有效，都有實跑證據；但每個審批提示上都有「允許並切到 accept edits」，選了之後檔案指令不再問，沒有設定能拿掉）。改用不問的模式，只放行 `<cubi> --tool-run sprint review.update '<JSON>'` 這一條；資料檔改放插件資料目錄的 `briefs/`；manifest 的命令要標 `sessionAllowed` 才能被放行。放行規則的寫法、here-document 與管線會被拒、接 `&&`／`;`／`|` 整條被拒、含空白的 `--add-dir` 讀得到，是審查員用非互動模式與假的 cubi 實跑的；我用真的 binary 在假資料上照資料檔的寫法寫回過一次（含單引號、換行、`$()`），內容原樣存進去。互動 session 還沒有實跑證據。真機待驗：回顧分頁「用 Claude 整理」→ 確認框寫「不會問你，只能執行這些動作：review.update」→ 開啟 → session 讀資料檔、寫回面板，全程沒有任何審批卡或提示，回顧出現在面板；叫它讀 `~/.config/atlassian/netrc` 或工作目錄外的檔 → 被拒；叫它 `touch x` → 被拒且沒有檔案；`~/Library/Application Support/cubi/sprint/briefs/` 底下有這期的資料檔，你的回顧資料夾沒有新檔；開啟 session 後故意不讓它寫回（例如直接關掉那個分頁）→ 3 分鐘後面板右下角出現「還沒收到回顧，請到終端看那個 session…」（這句離線渲染看過樣子，計時沒有等滿 3 分鐘驗）。
37. 11-12 Jira 刪掉的單與移出本期（真機回報：在 Jira 刪掉測試單後按「同步 Jira」，面板那張單沒變。實查 Jira：批次查詢對查不到的單不報錯、只是不回，單張查才回 404；插件原本只在整批報錯時才逐張查）。改成同步時逐張確認沒回來的單；面板多「Jira 查不到」標籤與每列的 ✕。單元測試用假的 Jira；離線渲染看過標籤、停用的按鈕，並實際點 ✕ 移出一張有工時的單（清單少一張、工時紀錄還在）。對真 Jira 還沒跑過。真機待驗：按「同步 Jira」→ 已在 Jira 刪掉的那張測試單，狀態變成紅色「Jira 查不到」，估點那格與旗子、沙漏是灰的；按它那列的 ✕ → 從表上消失，其他單都還在；再按一次同步不會回來。對一張專案沒有估點欄位的單改估點 → 右下角先是中文說明「這張單在 Jira 上不能寫估點…」，後面才是 Jira 的原文。
38. 11-13 面板右下角的錯誤訊息加 ✕（Jade 定案：錯誤不自動消失、可以手動關；成功訊息照舊 4 秒消失）。實際觀察到：等回顧時每 30 秒的背景同步會先顯示「…」再清空，把畫面上的錯誤洗掉，「還沒收到回顧」也會在關掉後被重新寫出來。改成背景同步不動右下角的訊息（失敗時照樣顯示錯誤）；「還沒收到回顧」被關掉後，同一次等待不再出現，沒關的話只在右下角沒有其他訊息時才補上；收到回顧時照樣顯示「Claude 寫回來了」。離線渲染加假時鐘跑過 18 個情境（錯誤有 ✕、關掉就消失；成功 4 秒消失且不會清掉後來的錯誤；下一則訊息蓋掉上一則；背景同步 60 秒後錯誤還在；關掉「還沒收到回顧」後輪詢不再顯示，收到回顧仍顯示「Claude 寫回來了」），也看過淺色、深色模式下長訊息換行與 ✕ 的位置。開 session 那一步是換成假的回應跑的，不是真的開 session。真機待驗：在面板做一件會失敗的事（例如工單表右上的「加單號」填 `abc` 按「＋ 加」），右下角紅底訊息的右側有 ✕、放著不會消失、按 ✕ 消失；做一件會成功的事，訊息 4 秒後消失、沒有 ✕；「用 Claude 整理」後 3 分鐘出現「還沒收到回顧」→ 按 ✕ → 之後不再出現，回顧寫回時仍出現「Claude 寫回來了」。
39. 11-13 右下角訊息的 ✕ 太小、難點（真機回報）。量到的原因：可點範圍只有圖示本身 14×14，訊息長到兩行時還被擠成 9×14。改成 32×32 的按鈕、圖示維持 14px，用負邊距讓訊息框不變高；滑過時有淡底色。離線渲染量過（淺色、深色各看過一張）：單行時訊息框 34 高、兩行 52 高，和改之前相同；按鈕兩種情況都是 32×32，四邊與內縮 4px 的角都點得到它，點了訊息消失。只動右下角的 ✕，其他 ✕ 沒動。滑過的底色離線渲染看不到。真機待驗：讓右下角出現錯誤（「加單號」填 `abc` 按「＋ 加」），✕ 周圍一圈都點得到、不用瞄準；長訊息時 ✕ 一樣大。

## 已知限制

- `cost.total_duration_ms`、`total_api_duration_ms`、`total_lines_*`、`version` 依官方文件解，實錄沒有 statusline 樣本。
- 回合數、工具呼叫數只算 Cubi 看到的；Cubi 重啟歸零。
- Claude app 裡的 session 在 /clear 或 compact 換了 CLI session id 後，app 會把紀錄的 `cliSessionId` 改成新的、舊的進 `previousCliSessionIds`（讀 5.1231.0 的 app.asar：`Mapping internal session … to CLI session …`、`preClearCliSessionId`、`cliSessionIdMoves`；沒親手按過）。Cubi 只比對現在的 `cliSessionId`，所以新 id 的機器人能跳、舊 id 的機器人（session 已結束）只切到 app。
- Ghostty 的 AppleScript 沒有 tty／pid 可比對（sdef 查過：terminal 只有 id、name、working directory），所以只能靠分頁標題；名字取自 Claude Code 的 `~/.claude/sessions/<pid>.json`（改名立刻有），標題比不到時 cwd 只在唯一時採用。同一目錄多個 session 且都沒名字的話，點了只會把 Ghostty 帶到前面、不切分頁。
- hooks 環境沒有 `TERM_PROGRAM`／tty 的 session（來源不明，log 曾出現）只能用名稱／cwd 猜終端，猜不到就不動。
- 離線渲染（`--render-island`）畫不出 `ScrollView` 內容，清單只能真機看。
- 瀏海面板 1400 pt：翼上 15 隻（含晚安膠囊）起 compact 的島左緣出面板被切；860 寬的資訊面板從同樣隻數起被壓窄到 854，此時機器人那排又會掛出島左緣（渲染 13／14／15 隻驗證：13 隻左緣 45 pt，14 隻 3 pt，15 隻被切）。浮動視窗沒有偏移，不受影響。
- 從瀏海拖出的瞬間島直接出現在滑鼠下方，沒有飛出動畫。
- 沒有 Apple 公證：下載的 app 會被 Gatekeeper 擋，install.sh 驗過簽章後拿掉 quarantine；手動裝的人要右鍵開啟或「隱私與安全性 → 強制打開」。憑證 hash 寫死在 install.sh，換憑證要同步改。
- 開 session：Ghostty 1.3.1 的 AppleScript `initial input` 會把非 ASCII 雙重編碼（繁中變成 `ç¥èåº«` 這種亂碼），所以指令改用 `input text` 打進新分頁（驗證過繁中原樣到達）；`input text` 靠 pty 緩衝，shell 啟動特別慢的機器理論上可能吃掉一截（沒遇過）。
- 開 session：Ghostty 慢到被 5 秒 watchdog 殺掉但分頁其實有開時，退路會在 Terminal.app 再開一個（推論，沒觸發過）。
- 沒有 `git push`（紅線），commit 由 Jade 推（2026-11-03 已推到 117341c，CI 綠）；Coucou 還沒 `brew uninstall --cask coucou`。

## 接下來

工具插件系統 2026-11-03 做完（第一個實例是 Jade 的私用面板，不在 repo）。再來要接其他 agent 的話，下面是現況與查到的事實。

### 額外 agent 插件

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

### 候選 agent 的已知事實（2026-11-03 查官方文件，兩個都沒裝在開發機上）

| | OpenAI Codex CLI | Gemini CLI |
|---|---|---|
| 文件 | https://learn.chatgpt.com/docs/hooks（developers.openai.com/codex/hooks 轉過去） | https://geminicli.com/docs/hooks/reference |
| 設定檔 | `~/.codex/hooks.json`（或 `config.toml` 的 `[[hooks.X]]`）、專案 `.codex/` 同名 | `~/.gemini/settings.json` 的 `hooks` 物件（專案 `.gemini/settings.json` 優先） |
| 條目形狀 | `"PreToolUse": [{ "matcher": "Bash", "hooks": [{ "type": "command", "command": "…", "timeout": 30 }] }]`，timeout 秒 | 同形狀，多 `name`／`description`／`sequential`，timeout 毫秒 |
| 事件 | SessionStart／SessionEnd／PreToolUse／**PermissionRequest**／PostToolUse／PreModelRequest／PostModelRequest／PreCompact／PostCompact／UserPromptSubmit／SubagentStart／SubagentStop／Stop／Interrupt | SessionStart／SessionEnd／BeforeTool／AfterTool／BeforeAgent／AfterAgent／BeforeModel／AfterModel／BeforeToolSelection／Notification／PreCompress |
| stdin 共同欄位 | `session_id`、`transcript_path`、`cwd`、`hook_event_name`、`model`；PreToolUse 多 `turn_id`、`tool_name`、`tool_use_id`、`tool_input`、`permission_mode` | `session_id`、`transcript_path`、`cwd`、`hook_event_name`、`timestamp`；工具事件多 `tool_name`、`tool_input` |
| 審批回覆 | `PermissionRequest` → `{"hookSpecificOutput":{"decision":{"behavior":"allow"|"deny","message":…}}}`，不回就走原本提示；PreToolUse 的 `permissionDecision` 支援 allow／deny，`ask` 「parsed but not supported」 | BeforeTool 只能 `decision: allow|deny`（policy，不是回應使用者的審批提示）；沒有 PermissionRequest；`Notification` 純觀測 |
| 問題卡（AskUserQuestion 類） | 文件沒有 | 文件沒有 |
| 旗標 | 預設開；非 managed 的 hook **要在 `/hooks` 審核信任（依 hash）才會跑**，裝完要使用者去按一次 | 文件沒標實驗；舊第三方資料說要開旗標，未查證 |
| 風險 | — | 文件註明 2026-06-18 起免費與 Google One 用戶被換成 Antigravity CLI，Gemini CLI 走向不明 |

結論：Codex 的事件與回覆幾乎是 Claude Code 的鏡像（PermissionRequest、PreToolUse、Stop、SessionStart/End、UserPromptSubmit），用現有 json-hooks 安裝器加一個 timeout 單位與 `PermissionRequest` 回覆模板就能做審批卡；Gemini 只能監看與 policy 擋，做不出「要不要允許」那張卡。
