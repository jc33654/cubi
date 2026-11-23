# 進階操作

README 講怎麼用；這裡是命令列，以及套件文件的入口，給要自己接東西的人。relay 的 socket 協定在 [protocol.md](protocol.md)。

## 套件

自建套件的文件在 `docs/plugins/`：

- [plugins/guide.md](plugins/guide.md)：自建套件指南，做出第一個套件。
- [plugins/reference.md](plugins/reference.md)：逐欄位規格、穩定度與相容承諾，包括 session hook、tick hook、樣式包、受限 session、agent 套件。
- [plugins/manifest.schema.json](plugins/manifest.schema.json)、[plugins/hook-io.schema.json](plugins/hook-io.schema.json)、[plugins/bridge.d.ts](plugins/bridge.d.ts)：給編輯器與 Claude Code 讀的格式。
- [plugins/claude-prompt.md](plugins/claude-prompt.md)：貼進 Claude Code 就能開始寫套件的提示範本。
- 內建的 sprint 套件：[plugins/sprint/README.md](plugins/sprint/README.md)。

## 命令列

```
~/Applications/Cubi.app/Contents/MacOS/cubi --version
~/Applications/Cubi.app/Contents/MacOS/cubi --hooks-status
~/Applications/Cubi.app/Contents/MacOS/cubi --hooks-plan            # 只印 diff，不寫
~/Applications/Cubi.app/Contents/MacOS/cubi --install-hooks         # 印 diff 後寫入（含備份）
~/Applications/Cubi.app/Contents/MacOS/cubi --uninstall-hooks
~/Applications/Cubi.app/Contents/MacOS/cubi --settings              # 啟動 app 並直接開設定頁
~/Applications/Cubi.app/Contents/MacOS/cubi --tool-run <id> <action> [args…]   # 走工具插件的路徑執行一條指令，印 {ok,out,err}；參數寫 - 就從 stdin 讀
~/Applications/Cubi.app/Contents/MacOS/cubi --validate-plugin <插件資料夾>     # 照 app 的規則檢查 manifest，加上面板檔與每個執行檔在不在、能不能執行；印出錯誤與警告，不開 app、不寫 log
~/Applications/Cubi.app/Contents/MacOS/cubi --new-session ~/proj [--continue | --resume <id>] [--prompt "第一句話"] [--terminal ghostty|terminal]   # 家目錄、根目錄、放金鑰的資料夾會被拒（exit 2）
```

例：`echo '{"id":"x","name":"PROJ-12 範例","cwd":"/tmp","agent":"claude-code","segments":[]}' | cubi --tool-run sprint session.info -`。

`--tool-run` 跟面板有三處不同：`reveal` 的命令只印出路徑、不在 Finder 選取；沒有時間上限（hook 命令在 app 裡是 20 秒）；每次執行與拒絕不寫進 log。找不到插件時會印出它被拒載的原因。

`--validate-plugin` 結束碼：`0` 載得進來（可能有警告）、`1` 有錯誤、`2` 用法錯。例：`cubi --validate-plugin docs/plugins/example-tool`。

`--hooks-plan` 與 `--install-hooks` 可加 `--retire-notify`：同時移除舊的 `notify-hook.sh` 桌面通知 hook（設定頁的同一個勾選）。CLI 跟 app 一樣以 `$HOME` 為家目錄；要對假目錄測就 `HOME=/tmp/x cubi --hooks-plan`。
