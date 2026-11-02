#!/bin/bash
# Builds "Kill Switch.app" into build/.
set -euo pipefail
cd "$(dirname "$0")"

APP="build/Kill Switch.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

# Explicit target: by default swiftc targets the SDK, which can be newer than the running system
swiftc -O -target "$(uname -m)-apple-macos14.0" -o "$APP/Contents/MacOS/KillSwitch" Sources/*.swift
cp Info.plist "$APP/Contents/Info.plist"
cp Resources/wgks-pf.sh Resources/AppIcon.icns "$APP/Contents/Resources/"
chmod 755 "$APP/Contents/Resources/wgks-pf.sh"
codesign --force --sign - "$APP"

echo "OK: $APP"
