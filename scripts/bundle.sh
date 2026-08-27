#!/bin/bash
# Build release and assemble Kapture.app.
#
# Local runs sign with an Apple Development identity, which keeps TCC grants stable across
# rebuilds. CI passes a Developer ID identity through the keychain and sets KAPTURE_VERSION,
# KAPTURE_BUILD and KAPTURE_PUBLIC_ED_KEY; only then does the app get a working updater and a
# signature macOS will accept on someone else's Mac.
set -e
cd "$(dirname "$0")/.."
export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
unset SDKROOT MACOSX_DEPLOYMENT_TARGET

VERSION="${KAPTURE_VERSION:-0.1.0}"
BUILD="${KAPTURE_BUILD:-1}"
PUBLIC_ED_KEY="${KAPTURE_PUBLIC_ED_KEY:-}"
# a fork points this at its own appcast; the app derives its download page from it too
FEED_URL="${KAPTURE_FEED_URL:-https://kapture.sh/appcast.xml}"

# -warnings-as-errors: project warnings fail the build (dependencies are unaffected)
# the rpath lets the executable find Sparkle.framework once it is inside the bundle
# capture output first so a failed build isn't masked by the grep filter — a stale
# .build/release/Kapture from an earlier run must never be bundled silently
build_out=$(/usr/bin/xcrun swift build -c release -Xswiftc -warnings-as-errors \
  -Xlinker -rpath -Xlinker @executable_path/../Frameworks 2>&1) || {
  printf '%s\n' "$build_out"
  echo "build failed"
  exit 1
}
printf '%s\n' "$build_out" | grep -vE "unhandled Platform key" || true
BIN=.build/release/Kapture
[ -f "$BIN" ] || { echo "build failed"; exit 1; }

APP=dist/Kapture.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" "$APP/Contents/Frameworks"
cp "$BIN" "$APP/Contents/MacOS/Kapture"
[ -f Resources/AppIcon.icns ] && cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
# MIT obliges us to ship the license text with the binary, not just name the project
[ -f LICENSE ] && cp LICENSE "$APP/Contents/Resources/LICENSE.txt"
[ -f THIRD-PARTY-NOTICES.md ] && cp THIRD-PARTY-NOTICES.md "$APP/Contents/Resources/"

# Sparkle ships as an XCFramework; the .app carries just the macOS slice, with its XPC services
# and Updater.app nested inside the framework where Sparkle expects to find them.
SPARKLE=$(find .build/artifacts -type d -name "Sparkle.framework" -path "*macos*" | head -1)
if [ -n "$SPARKLE" ]; then
  cp -R "$SPARKLE" "$APP/Contents/Frameworks/"
else
  echo "warning: Sparkle.framework not found — the app will not launch" >&2
fi

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleIdentifier</key><string>sh.kapture.app</string>
  <key>CFBundleName</key><string>Kapture</string>
  <key>CFBundleDisplayName</key><string>Kapture</string>
  <key>CFBundleExecutable</key><string>Kapture</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>${VERSION}</string>
  <key>CFBundleVersion</key><string>${BUILD}</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>LSUIElement</key><true/>
  <key>NSHighResolutionCapable</key><true/>
  <key>SUFeedURL</key><string>${FEED_URL}</string>
  <key>SUPublicEDKey</key><string>${PUBLIC_ED_KEY}</string>
  <key>SUEnableAutomaticChecks</key><true/>
  <key>SUScheduledCheckInterval</key><integer>86400</integer>
</dict></plist>
PLIST

# Prefer a real signing identity — a stable identity keeps TCC grants across rebuilds.
# Ad-hoc (-) changes identity every build, which resets Screen Recording permission.
SIGN_ID=$(security find-identity -v -p codesigning 2>/dev/null \
  | grep -oE '"(Developer ID Application|Apple Development)[^"]*"' | head -1 | tr -d '"')
SIGN_ID="${SIGN_ID:--}"

# Notarization requires the hardened runtime and a secure timestamp; a local Apple Development
# build skips both, since --timestamp needs the network and the runtime blocks the debugger.
EXTRA=()
case "$SIGN_ID" in
  "Developer ID Application"*) EXTRA=(--options runtime --timestamp) ;;
esac

# inside out: nested code first, then the app, so the outer signature seals what is already sealed
if [ -d "$APP/Contents/Frameworks/Sparkle.framework" ]; then
  while IFS= read -r nested; do
    codesign --force "${EXTRA[@]}" -s "$SIGN_ID" "$nested"
  done < <(find "$APP/Contents/Frameworks/Sparkle.framework" \
    \( -name "*.xpc" -o -name "*.app" -o -name "Autoupdate" \) -maxdepth 4)
  codesign --force "${EXTRA[@]}" -s "$SIGN_ID" "$APP/Contents/Frameworks/Sparkle.framework"
fi
codesign --force "${EXTRA[@]}" -s "$SIGN_ID" "$APP"
echo "signed as: $SIGN_ID"
[ -n "$PUBLIC_ED_KEY" ] || echo "note: no SUPublicEDKey — in-app updates are disabled in this build"
echo "built $APP ($VERSION build $BUILD) — run with: open $APP"
