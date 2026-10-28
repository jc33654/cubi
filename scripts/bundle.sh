#!/usr/bin/env bash
# Assemble build/Cubi.app from the release build and sign it.
#
# Signing identity: $CUBI_SIGN_IDENTITY, default "cubi-dev" (a self-signed Code Signing certificate
# made once in Keychain Access). With a stable certificate the designated requirement is
# "identifier + certificate leaf", so TCC grants (Automation, notifications) survive rebuilds.
# Without it we fall back to ad-hoc signing and warn: every rebuild would then lose those grants.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

APP="build/Cubi.app"
IDENTITY="${CUBI_SIGN_IDENTITY:-cubi-dev}"
BUNDLE_ID="cc.dotdot.cubi"

swift build -c release

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp .build/release/cubi .build/release/cubi-hook "$APP/Contents/MacOS/"
cp Packaging/Info.plist "$APP/Contents/Info.plist"

BUILD_NUMBER="$(git rev-list --count HEAD 2>/dev/null || echo 1)"
/usr/libexec/PlistBuddy -c "Set :CFBundleVersion $BUILD_NUMBER" "$APP/Contents/Info.plist"

# SwiftPM resource bundle (index.html, fixtures…). Bundle.module looks next to the executable's
# bundle first, so copying it into Contents/Resources makes `swift run` and the .app agree.
if [ -d .build/release/cubi_cubi.bundle ]; then
  cp -R .build/release/cubi_cubi.bundle "$APP/Contents/Resources/"
fi

if [ -f build/cubi.icns ]; then
  cp build/cubi.icns "$APP/Contents/Resources/cubi.icns"
else
  echo "note: build/cubi.icns missing, run 'make icon' for an app icon"
fi

if security find-identity -p codesigning 2>/dev/null | grep -q "\"$IDENTITY\""; then
  SIGN="$IDENTITY"
else
  echo "warning: signing identity '$IDENTITY' not found; using ad-hoc signing." >&2
  echo "         TCC grants will NOT survive rebuilds. See 'make cert'." >&2
  SIGN="-"
fi

# Nested executables are not sealed by the outer signature: sign the relay first, then the app.
codesign --force --timestamp=none --sign "$SIGN" --identifier "$BUNDLE_ID-hook" "$APP/Contents/MacOS/cubi-hook"
codesign --force --timestamp=none --sign "$SIGN" --identifier "$BUNDLE_ID" "$APP"
codesign --verify --strict "$APP"

echo "built $APP (build $BUILD_NUMBER, signed with: $SIGN)"
