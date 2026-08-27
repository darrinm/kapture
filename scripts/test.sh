#!/bin/bash
# Run the Swift test suite. Mirrors bundle.sh's toolchain setup: an inherited SDKROOT from an
# Xcode-launched shell pins an older SDK than the selected compiler and the build fails on
# "this SDK is not supported by the compiler".
set -e
cd "$(dirname "$0")/.."
export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
unset SDKROOT MACOSX_DEPLOYMENT_TARGET
exec /usr/bin/xcrun swift test "$@"
