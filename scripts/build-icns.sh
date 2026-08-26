#!/bin/bash
# Mask the raw generated icon to a transparent squircle, then build Resources/AppIcon.icns.
set -e
cd "$(dirname "$0")/.."
export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
unset SDKROOT MACOSX_DEPLOYMENT_TARGET
/usr/bin/xcrun swift scripts/mask-icon.swift
rm -rf /tmp/Kapture.iconset && mkdir /tmp/Kapture.iconset
for s in 16 32 64 128 256 512; do
  sips -z $s $s Resources/icon-masked.png --out /tmp/Kapture.iconset/icon_${s}x${s}.png >/dev/null
  d=$((s*2))
  sips -z $d $d Resources/icon-masked.png --out /tmp/Kapture.iconset/icon_${s}x${s}@2x.png >/dev/null
done
iconutil -c icns /tmp/Kapture.iconset -o Resources/AppIcon.icns
echo "AppIcon.icns rebuilt"
