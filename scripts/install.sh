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
    cp "$CUBI_LOCAL_ZIP" "$zip"
    if [ -f "$CUBI_LOCAL_ZIP.sha256" ]; then cp "$CUBI_LOCAL_ZIP.sha256" "$zip.sha256"; fi
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
    if ! (cd "$work" && shasum -a 256 -c Cubi.zip.sha256 >/dev/null 2>&1); then
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

  if ! codesign --verify --strict -R="$REQUIREMENT" "$app" 2>"$work/codesign.err"; then
    echo "簽章不符：這個包不是用 Cubi 的 cubi-dev 憑證簽的。沒有安裝、沒有拿掉 quarantine。" >&2
    cat "$work/codesign.err" >&2
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
  pkill -x cubi 2>/dev/null || true
  rsync -a --delete "$app/" "$DEST/"
  # Not notarized by Apple, so Gatekeeper would refuse to open it. The signature check above is
  # what we trust instead; this is the step Gatekeeper would otherwise have blocked.
  xattr -dr com.apple.quarantine "$DEST" 2>/dev/null || true
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
