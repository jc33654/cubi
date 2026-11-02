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
# The release build carries debug stabs that name every object file by absolute path
# (/Users/<you>/.../X.swift.o). Strip them: nothing from this machine belongs in the bundle.
strip -S "$APP/Contents/MacOS/cubi" "$APP/Contents/MacOS/cubi-hook"
cp Packaging/Info.plist "$APP/Contents/Info.plist"

BUILD_NUMBER="$(git rev-list --count HEAD 2>/dev/null || echo 1)"
/usr/libexec/PlistBuddy -c "Set :CFBundleVersion $BUILD_NUMBER" "$APP/Contents/Info.plist"

# Marketing version: the tag we are exactly on (v0.2.0 → 0.2.0), otherwise what Info.plist says.
# A commit past a tag would give "v0.2.0-3-gabc1234", which is not a valid version string.
if TAG="$(git describe --tags --match 'v*' --exact-match 2>/dev/null)"; then
  /usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString ${TAG#v}" "$APP/Contents/Info.plist"
fi
VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$APP/Contents/Info.plist")"
if ! [[ "$VERSION" =~ ^[0-9]+(\.[0-9]+)*$ ]]; then
  echo "error: CFBundleShortVersionString '$VERSION' is not digits and dots" >&2
  exit 1
fi

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

# Gate: no path from the build machine may survive into the bundle. "/Users/me" is the sample
# data IconRenderer draws in --render-island previews, not a real home.
for bin in "$APP/Contents/MacOS/cubi" "$APP/Contents/MacOS/cubi-hook"; do
  if leaked="$(grep -a -o '/Users/[^/"]*' "$bin" | grep -v -x '/Users/me' | sort -u)" && [ -n "$leaked" ]; then
    echo "error: $bin still contains local paths:" >&2
    echo "$leaked" >&2
    exit 1
  fi
done

echo "built $APP (version $VERSION, build $BUILD_NUMBER, signed with: $SIGN)"
