#!/bin/bash
# Regenerates Resources/AppIcon.icns (drawing in tools/make-icon.swift and Sources/Keyhole.swift).
set -euo pipefail
cd "$(dirname "$0")/.."

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

# With several files, only main.swift may contain top-level code
cp tools/make-icon.swift "$work/main.swift"
swiftc -O -target "$(uname -m)-apple-macos14.0" -o "$work/make-icon" "$work/main.swift" Sources/Keyhole.swift
"$work/make-icon" "$work/AppIcon.iconset"
iconutil -c icns "$work/AppIcon.iconset" -o Resources/AppIcon.icns

echo "OK: Resources/AppIcon.icns"
