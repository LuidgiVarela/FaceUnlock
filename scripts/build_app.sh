#!/bin/zsh
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"

if [[ -f "$ROOT/.env.local" ]]; then
  source "$ROOT/.env.local"
fi

APP="${FACEUNLOCK_APP_PATH:-$HOME/Applications/FaceUnlock.app}"
CONTENTS="$APP/Contents"
MACOS="$CONTENTS/MacOS"
RESOURCES="$CONTENTS/Resources"
EXECUTABLE="$MACOS/faceunlock"
CONFIG="${FACEUNLOCK_BUILD_CONFIG:-debug}"
BUNDLE_ID="${FACEUNLOCK_BUNDLE_ID:-com.example.FaceUnlock}"
SIGNING_IDENTITY="${FACEUNLOCK_SIGNING_IDENTITY:-}"
ICON_SOURCE="$ROOT/Assets/AppIcon/FaceUnlock-logo.png"
ICONSET="$ROOT/.build/FaceUnlock.iconset"

cd "$ROOT"
swift build -c "$CONFIG" --arch arm64

rm -rf "$APP"
mkdir -p "$MACOS" "$RESOURCES"
cp "$ROOT/.build/arm64-apple-macosx/$CONFIG/faceunlock" "$EXECUTABLE"

cat > "$CONTENTS/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleDevelopmentRegion</key>
  <string>en</string>
  <key>CFBundleExecutable</key>
  <string>faceunlock</string>
  <key>CFBundleIdentifier</key>
  <string>${BUNDLE_ID}</string>
  <key>CFBundleIconFile</key>
  <string>FaceUnlock</string>
  <key>CFBundleInfoDictionaryVersion</key>
  <string>6.0</string>
  <key>CFBundleName</key>
  <string>FaceUnlock</string>
  <key>CFBundleDisplayName</key>
  <string>FaceUnlock</string>
  <key>CFBundlePackageType</key>
  <string>APPL</string>
  <key>CFBundleShortVersionString</key>
  <string>0.1.0</string>
  <key>CFBundleVersion</key>
  <string>1</string>
  <key>LSMinimumSystemVersion</key>
  <string>14.0</string>
  <key>LSUIElement</key>
  <true/>
  <key>NSCameraUsageDescription</key>
  <string>FaceUnlock uses the camera only while the Mac is locked or while enrolling/testing your face.</string>
  <key>NSHumanReadableCopyright</key>
  <string>Experimental local FaceUnlock prototype.</string>
</dict>
</plist>
PLIST

cat > "$CONTENTS/PkgInfo" <<'PKG'
APPL????
PKG

if [[ -f "$ICON_SOURCE" ]]; then
  rm -r "$ICONSET" 2>/dev/null || true
  mkdir -p "$ICONSET"
  sips -z 16 16 "$ICON_SOURCE" --out "$ICONSET/icon_16x16.png" >/dev/null
  sips -z 32 32 "$ICON_SOURCE" --out "$ICONSET/icon_16x16@2x.png" >/dev/null
  sips -z 32 32 "$ICON_SOURCE" --out "$ICONSET/icon_32x32.png" >/dev/null
  sips -z 64 64 "$ICON_SOURCE" --out "$ICONSET/icon_32x32@2x.png" >/dev/null
  sips -z 128 128 "$ICON_SOURCE" --out "$ICONSET/icon_128x128.png" >/dev/null
  sips -z 256 256 "$ICON_SOURCE" --out "$ICONSET/icon_128x128@2x.png" >/dev/null
  sips -z 256 256 "$ICON_SOURCE" --out "$ICONSET/icon_256x256.png" >/dev/null
  sips -z 512 512 "$ICON_SOURCE" --out "$ICONSET/icon_256x256@2x.png" >/dev/null
  sips -z 512 512 "$ICON_SOURCE" --out "$ICONSET/icon_512x512.png" >/dev/null
  sips -z 1024 1024 "$ICON_SOURCE" --out "$ICONSET/icon_512x512@2x.png" >/dev/null
  iconutil -c icns "$ICONSET" -o "$RESOURCES/FaceUnlock.icns"
fi

xattr -cr "$APP"
if [[ -z "$SIGNING_IDENTITY" ]]; then
  SIGNING_IDENTITY="$(security find-identity -v -p codesigning 2>/dev/null | awk -F '\"' '/Apple Development:/ { print $2; exit }')"
fi

if [[ -n "$SIGNING_IDENTITY" ]]; then
  echo "Signing identity: $SIGNING_IDENTITY"
  codesign --force --sign "$SIGNING_IDENTITY" --timestamp=none "$APP"
else
  echo "Signing identity: ad-hoc"
  codesign --force --sign - --timestamp=none "$APP"
fi
xattr -cr "$APP"

echo "App bundle created: $APP"
echo "Bundle identifier: $BUNDLE_ID"
file "$EXECUTABLE"
codesign --verify --deep --strict --verbose=2 "$APP"
