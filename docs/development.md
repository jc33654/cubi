# 開發與發版

README 放的是給使用者看的東西；這裡是改程式、打包、發版的細節。

## 目錄

```
Sources/CubiKit/     純邏輯：事件模型、解碼、session 狀態機、回覆編碼、安裝器、plugin 協定（可測）
Sources/cubi/        AppKit + SwiftUI app；Plugins/（面板、hook 執行、資訊窗掛件、ticker）、Calendar/（EventKit）
Sources/cubi-hook/   relay，只 import Darwin，冷啟動個位數 ms
Tests/CubiKitTests/  單元測試；Fixtures/claude-2.1.312/ 是實錄的 hook payload
scripts/             bundle.sh（打包、strip、簽章、路徑守門）、install.sh（使用者安裝）、install-plugin.sh（複製插件到 plugins/）、make-icns.sh、import-fixtures.py
.github/workflows/   ci.yml、release.yml
docs/                plan.md（設計與決策）、protocol.md（relay socket 協定）、advanced.md（插件規格、CLI、行事曆規則）、status.md（進度）、plugins/（範例與內建插件）、images/（README 的圖）
```

## make 目標

| 目標 | 做什麼 |
|---|---|
| `make build` / `make release` | debug / release 建置到 `.build/` |
| `make test` | 跑 CubiKit 單元測試（CLT 的 swift-testing 需要額外 rpath，Makefile 已處理） |
| `make plugin-test` | 跑 `docs/plugins/sprint/` 的 Python unittest |
| `make cert` | 檢查簽章憑證 `cubi-dev`，第一次會告訴你怎麼建 |
| `make icon` | 由程式自己畫出 app icon |
| `make bundle` | 只打包簽章到 `build/Cubi.app`，不安裝；會 strip 掉 debug 符號，並檢查兩個執行檔裡沒有任何 `/Users/…` 本機路徑，有就失敗 |
| `make dist` | `make bundle` 再壓成 `build/Cubi.zip` + `Cubi.zip.sha256`（release 用的固定檔名） |
| `make install` | 建置、打包、簽章、安裝到 `~/Applications/Cubi.app` |
| `make run` | 安裝並重啟 app |
| `make hook-test` | app 沒開時餵 relay 一筆假資料，必須 exit 0 且無輸出 |

## 常用的驗證方式

- `make test`
- 離線渲染島：`.build/release/cubi --render-island <hidden|compact|expanded|detail|approval|question|usage|usage-compact|diff|floating|floating-approval> <botState> out.png`；環境變數 `CUBI_RENDER_BOTS=n` 畫 n 隻（預設 4，第三隻在晚安區）、`CUBI_RENDER_BOT_SIZE=small|large` 換機器人大小（預設 regular，不吃這台機器的設定）。README 的圖就是這樣渲染再裁的；`ScrollView`（session 清單）畫不出來，所以沒有 expanded 清單的圖。
- 離線渲染工具插件面板：`cubi --render-panel <tool id> out.png [--dark] [--height N] [--eval JS]`。真的 web view、真的 bridge（命令會真的執行），視窗在螢幕外；`--eval` 在載入後跑，2 秒後截圖，`eval →` 印出回傳值。要測非同步的東西就在 JS 裡 `setTimeout` 之後把結果寫進 `document.body` 再讀截圖。插件要指到假資料（sprint 用 `CUBI_SPRINT_DIR`，HOME 也換成暫存目錄、把插件複製進去），不然會動到真的資料。注意 `focus()` 對隱藏分頁或收起的 `<details>` 裡的元素無效。
- 離線渲染資訊窗裡工具插件的區塊：`cubi --render-widget <tool id> "<session 名>" out.png`。真的跑插件的 `session.info`（假 session，id `render-widget`、沒有 cwd 與活動時段），只畫列（含列尾按鈕），不畫底部按鈕列。插件一樣要指到假資料（sprint 會替這個假 session 寫一筆綁定）。
- 離線渲染設定頁：`cubi --render-settings <claude|display|sleep|calendar|plugins|scope> out.png [--dark]`。讀這台機器真的設定，不建立 Notifier、不寫設定（會建 plugins 目錄、寫一行 log）。視窗在螢幕外、不是作用中視窗，所以按鈕與開關畫成灰色，強調色要真機看。
- 重播實錄 payload：`python3 -c 'import json;print(json.dumps(json.load(open("Tests/CubiKitTests/Fixtures/claude-2.1.312/SessionStart-1.json"))["payload"]))' | ~/.cubi/bin/cubi-hook --agent claude-code --event SessionStart`
- 錄新版 Claude Code 的 payload：先 `make release`（capture 用的是 `.build/release/cubi-hook`），repo 要在 `$HOME/Documents/cubi`（`docs/capture.settings.local.json` 寫死這個路徑，放別處就改它）。把那份 hooks 放進某個專案的 `.claude/settings.local.json`，跑一輪後用 `scripts/import-fixtures.py <版本>` 匯入（會把路徑洗掉）。錄完要把那些 hooks 拿掉，不然該專案的事件會重複觸發：在 `~/Documents/cubi` 錄的可以在設定頁按「移除」（預設只看這個目錄），在別的專案錄的要自己手動刪。

## 命令列

全部列在 [advanced.md](advanced.md) 的「命令列」。開發時常用：`--tool-run <id> <action> -`（參數 `-` 從 stdin 讀，餵 hook 命令的 JSON）、`HOME=/tmp/x cubi --hooks-plan`（對假目錄測）。

## 自簽憑證 `cubi-dev`

沒有 Developer ID 也能用，但要有一張**穩定的**憑證：macOS 的 TCC（Automation、通知授權）認的是「bundle id + 憑證」，ad-hoc 簽章每次重編都會變，授權就會靜默失效。所以一次性在 Keychain Access 建一張：

1. 開 **Keychain Access** → 選單 **Keychain Access → Certificate Assistant → Create a Certificate…**
2. Name：`cubi-dev`；Identity Type：**Self Signed Root**；Certificate Type：**Code Signing**
3. Create。之後 `make cert` 會回報 `identity 'cubi-dev' found`。

沒有這張憑證時 `make install` 會退回 ad-hoc 簽章並印警告，app 仍可用，但每次重編後要重新授權 Automation。

## 發版

1. 一次性：把 `cubi-dev` 憑證放進 GitHub secrets。Keychain Access → 我的憑證 → `cubi-dev` → 右鍵「輸出」存成 `.p12`（設一個密碼），然後 `base64 -i cubi-dev.p12 | pbcopy`。到 repo Settings → Secrets and variables → Actions 新增 `CUBI_CERT_P12`（貼上）與 `CUBI_CERT_PASSWORD`。匯出後把 `.p12` 刪掉。
2. 每次：`git tag v0.2.0 && git push origin v0.2.0`。`.github/workflows/release.yml` 會在 macOS runner 跑測試、用這張憑證簽、把 `Cubi.zip` 與 `Cubi.zip.sha256` 掛到 Release，release notes 由 commit 自動生成。版本號來自 tag（`bundle.sh` 只在剛好在 tag 上時覆寫 `CFBundleShortVersionString`）；打 tag 前先把 `Packaging/Info.plist` 與 `CubiInfo.version` 改成同一個號碼，`make bundle` 會檢查兩者一致。只接受 `vX.Y.Z`，`-rc` 之類的 tag 不會觸發。
3. 備援：本機 `make dist`，把 `build/Cubi.zip` 與 `.sha256` 手動上傳到 Release。

**把私鑰放 GitHub secrets 的風險**：有 repo 寫入權或能跑 Actions 的人可能拿到它；拿到只能簽出「在已裝 Cubi 的機器上繼承 Automation 授權」的假 app，Gatekeeper 仍不信任那張憑證。fork 來的 PR 讀不到 secrets，`ci.yml` 也不引用 secrets。懷疑外洩或換憑證的順序（`release.yml` 讀的是**被 tag 的那個 commit** 裡的 `scripts/install.sh`，所以新 hash 必須已經在那個 commit 裡）：

1. `make cert` 重建憑證，換 secrets。
2. 本機改 `scripts/install.sh` 的 `REQUIREMENT`（只有這一處），commit。
3. 在同一個 commit 上打 tag，**只 push tag**：`git push origin v0.2.0`，先不 push `main`。
4. Actions 綠了、Release 掛上新 zip 之後，再 `git push origin main`。

順序反過來會有空窗：`main` 上的腳本要求新憑證，Releases 上的 zip 還是舊憑證簽的，所有 `curl | bash` 都會「簽章不符」；tag 打在舊 hash 的 commit 上則 verify 步驟一定失敗。使用者更新後要重新授權一次 Automation。

`ci.yml` 在 push `main` 與 PR 時跑 `swift test`、`make bundle`（沒憑證走 ad-hoc，仍會跑本機路徑守門）。

## 設計上刻意的事

- 協定與做法借自 [Coucou](https://github.com/louis-cfm/coucou)（MIT），程式碼與素材都是自己的。
- relay 等回覆最多 115 秒（hook timeout 120），app 沒開或當掉時 Claude Code 自動退回終端自己問。
- 每條連線一個待決請求，以 fd 為鍵；終端先答了就關連線，卡片跟著收。
- 用量讀數跨 session 合併：只有最近有活動的 session 能覆寫 5h / 7d，閒置 session 送來的空值不會清掉既有數字。
- 島在瀏海兩側不對稱（機器人那翼會變寬）：整個島往左挪讓瀏海留白永遠對準瀏海，compact 與 expanded 都一樣；面板本身 1400 pt 寬、透明，容得下十幾隻。
