#!/bin/bash
# Build release and assemble Kapture.app (ad-hoc signed for local use; CI signs for real).
set -e
cd "$(dirname "$0")/.."
export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
unset SDKROOT MACOSX_DEPLOYMENT_TARGET
# -warnings-as-errors: project warnings fail the build (dependencies are unaffected)
/usr/bin/xcrun swift build -c release -Xswiftc -warnings-as-errors 2>&1 | grep -vE "unhandled Platform key" || true
BIN=.build/release/Kapture
[ -f "$BIN" ] || { echo "build failed"; exit 1; }

APP=dist/Kapture.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/Kapture"
[ -f Resources/AppIcon.icns ] && cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleIdentifier</key><string>sh.kapture.app</string>
  <key>CFBundleName</key><string>Kapture</string>
  <key>CFBundleDisplayName</key><string>Kapture</string>
  <key>CFBundleExecutable</key><string>Kapture</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>0.1.0</string>
  <key>CFBundleVersion</key><string>1</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>LSUIElement</key><true/>
  <key>NSHighResolutionCapable</key><true/>
</dict></plist>
PLIST
# Prefer a real signing identity — a stable identity keeps TCC grants across rebuilds.
# Ad-hoc (-) changes identity every build, which resets Screen Recording permission.
SIGN_ID=$(security find-identity -v -p codesigning 2>/dev/null \
  | grep -oE '"(Developer ID Application|Apple Development)[^"]*"' | head -1 | tr -d '"')
codesign --force --deep -s "${SIGN_ID:--}" "$APP"
echo "signed as: ${SIGN_ID:-ad-hoc}"
echo "built $APP — run with: open $APP"
