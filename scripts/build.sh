#!/bin/bash
set -euo pipefail

cd "$(dirname "$0")/.."
APP="dist/EyeBreak.app"
mkdir -p "$APP/Contents/MacOS"
xcrun swiftc -O -target "$(uname -m)-apple-macosx13.0" Sources/main.swift -o "$APP/Contents/MacOS/EyeBreak" -framework AppKit -framework ServiceManagement
cp Info.plist "$APP/Contents/Info.plist"
codesign --force --sign - "$APP"
printf 'Built %s/dist/EyeBreak.app\n' "$PWD"
