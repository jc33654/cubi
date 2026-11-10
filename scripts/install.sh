#!/bin/bash
# Install or update Cubi from GitHub Releases, no Xcode or certificate needed.
#
#   curl -fsSL https://raw.githubusercontent.com/jc33654/cubi/main/scripts/install.sh | bash
#   CUBI_VERSION=v0.2.0 bash install.sh      a specific release instead of the latest
#   CUBI_LOCAL_ZIP=build/Cubi.zip bash install.sh   a zip from `make dist`, no download
#
# Everything runs inside main() so a half-downloaded script does nothing.
set -euo pipefail

REPO="jc33654/cubi"
DEST="$HOME/Applications/Cubi.app"
# What a genuine build must satisfy: the bundle id and the SHA-1 of the cubi-dev signing
# certificate. Regenerating the certificate (make cert) means changing this line too.
REQUIREMENT='identifier "cc.dotdot.cubi" and certificate leaf = H"902124bf301876614e89d5ea26b874c6d0487189"'

main() {
  if [ "$(uname -s)" != "Darwin" ]; then
    echo "Cubi 只能裝在 macOS" >&2
    exit 1
  fi

  local work zip app base new old
  work="$(mktemp -d -t cubi-install)"
  zip="$work/Cubi.zip"

  if [ -n "${CUBI_LOCAL_ZIP:-}" ]; then
    zip="$CUBI_LOCAL_ZIP"
  else
    if [ -n "${CUBI_VERSION:-}" ]; then
      base="https://github.com/$REPO/releases/download/$CUBI_VERSION"
    else
      base="https://github.com/$REPO/releases/latest/download"
    fi
    echo "下載 $base/Cubi.zip"
    curl -fsSL --retry 3 -o "$zip" "$base/Cubi.zip"
    curl -fsSL --retry 3 -o "$zip.sha256" "$base/Cubi.zip.sha256"
  fi

  # Integrity only: the checksum comes from the same release as the zip, so it catches a
  # damaged download, not a replaced release. Origin is checked by the signature below.
  if [ -f "$zip.sha256" ]; then
    if [ "$(shasum -a 256 "$zip" | cut -d' ' -f1)" != "$(cut -d' ' -f1 "$zip.sha256")" ]; then
      echo "完整性校驗失敗：Cubi.zip 跟 Cubi.zip.sha256 對不上，沒有安裝" >&2
      exit 1
    fi
  fi

  ditto -x -k "$zip" "$work"
  app="$work/Cubi.app"
  if [ ! -d "$app" ]; then
    echo "zip 裡沒有 Cubi.app，沒有安裝" >&2
    exit 1
  fi

  if ! codesign --verify --strict -R="$REQUIREMENT" "$app"; then
    echo "簽章不符：這個包不是用 Cubi 的 cubi-dev 憑證簽的。沒有安裝、沒有拿掉 quarantine。" >&2
    echo "解開的檔案留在 ${app}，可以自己檢查。" >&2
    exit 1
  fi

  new="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$app/Contents/Info.plist")"
  if [ -d "$DEST" ]; then
    old="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$DEST/Contents/Info.plist" 2>/dev/null || echo '?')"
    echo "更新 Cubi $old → $new"
  else
    echo "安裝 Cubi $new"
  fi

  mkdir -p "$HOME/Applications"
  # Only the installed copy, not a developer's `swift run`. A second instance quits itself when it
  # sees the first one, so wait for the old one to be gone before launching the new one.
  pkill -f "$DEST/Contents/MacOS/cubi" 2>/dev/null || true
  for _ in $(seq 1 25); do
    pgrep -f "$DEST/Contents/MacOS/cubi" >/dev/null || break
    sleep 0.2
  done
  rsync -a --delete "$app/" "$DEST/"
  # Not notarized by Apple, so Gatekeeper would refuse to open it. The signature check above is
  # what we trust instead; this is the step Gatekeeper would otherwise have blocked.
  xattr -dr com.apple.quarantine "$DEST" 2>/dev/null || true
  # 「重開 Cubi」: a fresh process even while Cubi runs (Finder only re-activates it); a stuck copy is replaced.
  osacompile -o "$HOME/Applications/重開 Cubi.app" -e "do shell script \"open -n \" & quoted form of \"$DEST\"" \
    || echo "warn: 沒能建立「重開 Cubi.app」，Cubi 本身已裝好" >&2
  # $work stays in $TMPDIR (macOS purges it); on failure it is what you inspect.

  open "$DEST"
  cat <<EOF
Cubi $new 已啟動。接下來：
  1. 設定頁按「安裝…」，看完 diff 按「寫入」（把 hooks 寫進 ~/.claude/settings.json）
  2. 重開已開著的 Claude Code：hooks 在 session 啟動時讀取
  3. 第一次點機器人跳回終端時，macOS 會問 Automation 授權，按允許
EOF
}

main "$@"
