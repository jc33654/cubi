# 發版檢查清單

照順序做。每一步的指令都可以直接貼，在 Cubi 原始碼資料夾裡執行。原理、憑證與 secrets 怎麼設，見 [development.md](development.md) 的「發版」。下面以 v0.2.0 為例。

## 0. 前提（只要確認一次）

- 本機有 `cubi-dev` 憑證：`make cert` 印出 `identity 'cubi-dev' found`。
- GitHub repo 的 Settings → Secrets and variables → Actions 有 `CUBI_CERT_P12` 與 `CUBI_CERT_PASSWORD`。

## 1. 版本號與工作樹

```sh
git switch main && git pull --ff-only
git status --short                         # 應該沒有輸出
/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' Packaging/Info.plist   # 0.2.0
grep 'public static let version' Sources/CubiKit/CubiKit.swift                       # "0.2.0"
```

兩處都要是 `0.2.0`，而且一樣：`make bundle` 會檢查兩者一致，Release 也會檢查 zip 裡的版本等於 tag。

## 2. 測試

```sh
make test && make plugin-test
```

兩個都要全過。

## 3. 本機打包並照安裝腳本的方式檢查

```sh
make icon && make dist
cd build && shasum -a 256 -c Cubi.zip.sha256 && cd ..
D=$(mktemp -d) && ditto -x -k build/Cubi.zip "$D"
codesign --verify --strict -R="$(sed -n "s/^REQUIREMENT='\(.*\)'$/\1/p" scripts/install.sh)" "$D/Cubi.app" && echo "簽章 OK"
/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$D/Cubi.app/Contents/Info.plist"   # 0.2.0
```

`make dist` 最後一行要寫 `built build/Cubi.app (version 0.2.0, …, signed with: cubi-dev)`。如果寫 `signed with: -`，表示沒找到憑證，不要發。

## 4. 本機試裝這個 zip

```sh
CUBI_LOCAL_ZIP=build/Cubi.zip bash scripts/install.sh
~/Applications/Cubi.app/Contents/MacOS/cubi --version      # cubi 0.2.0
```

這一步會把你自己裝的 Cubi 換成這一版並重開。重開後確認這幾件事：

- 島正常出現，機器人照常更新。
- 設定 › Claude Code 顯示 hooks「已安裝」。
- 設定 › 插件 沒有紅字。
- sprint 從原始碼重裝一次，確認照常：`scripts/install-plugin.sh docs/plugins/sprint`，再到設定 › 插件按「重新載入」、打開 sprint 面板。

## 5. 推 main，等 CI 綠

```sh
git push origin main
```

到 GitHub 的 Actions 看 `ci` 這個 workflow 跑完是綠的。

## 6. 打 tag，等 Release

```sh
git tag v0.2.0 && git push origin v0.2.0
```

Actions 裡的 `release` workflow 會依序：跑測試、用 secrets 裡的憑證簽、照安裝腳本的方式驗 zip、把 `Cubi.zip` 與 `Cubi.zip.sha256` 掛到 Release。看它跑完是綠的。

## 7. Release 頁

- 到 repo 的 Releases 打開 v0.2.0，確認附檔有 `Cubi.zip` 與 `Cubi.zip.sha256` 兩個。
- 說明欄預設是從 commit 自動產生的清單。按 Edit，換成 [CHANGELOG.md](CHANGELOG.md) 裡 v0.2.0 那一段，然後儲存。

## 8. 從網路裝一次

README 與 CHANGELOG 叫使用者 `git clone --branch v0.2.0` 裝 sprint，這個 tag 要第 6 步推上去之後才存在；確認一下：

```sh
D=$(mktemp -d) && git clone -q --branch "v$(~/Applications/Cubi.app/Contents/MacOS/cubi --version | cut -d' ' -f2)" --depth 1 https://github.com/jc33654/cubi.git "$D/cubi" && ls "$D/cubi/scripts/install-plugin.sh"
```

再用安裝腳本從網路裝一次：

```sh
curl -fsSL https://raw.githubusercontent.com/jc33654/cubi/main/scripts/install.sh | bash
~/Applications/Cubi.app/Contents/MacOS/cubi --version      # cubi 0.2.0
```

安裝腳本應該印出 `更新 Cubi 0.2.0 → 0.2.0`（如果先做了第 4 步）或 `安裝 Cubi 0.2.0`，沒有「完整性校驗失敗」或「簽章不符」。

## 出錯時

- `release` workflow 失敗：看 Actions 的 log。修好之後發新的版本號（例如 v0.2.1），不要重用同一個 tag。
- 換了憑證：順序跟平常不同，照 development.md「把私鑰放 GitHub secrets 的風險」那段做。
