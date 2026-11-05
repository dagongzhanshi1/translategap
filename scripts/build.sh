#!/bin/bash
set -euo pipefail
export DEVELOPER_DIR=/Library/Developer/CommandLineTools
TASK_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TASK_APP="${TRANSLATEGAP_APP_PATH:-$TASK_ROOT/dist/译隙.app}"
TASK_BUILD="${TRANSLATEGAP_BUILD_PATH:-$TASK_ROOT/.build}"
TASK_SWIFTC="/Library/Developer/CommandLineTools/usr/bin/swiftc"
TASK_SDK="/Library/Developer/CommandLineTools/SDKs/MacOSX.sdk"
mkdir -p "$TASK_APP/Contents/MacOS" "$TASK_APP/Contents/Resources" "$TASK_BUILD"
"$TASK_SWIFTC" -parse-as-library -swift-version 5 -O -sdk "$TASK_SDK" -target arm64-apple-macosx13.0 -framework AppKit -framework SwiftUI -framework Combine -framework Carbon -framework Security "$TASK_ROOT"/Sources/*.swift -o "$TASK_BUILD/TranslateGap"
cp "$TASK_BUILD/TranslateGap" "$TASK_APP/Contents/MacOS/TranslateGap"
cp "$TASK_ROOT/Info.plist" "$TASK_APP/Contents/Info.plist"
cp "$TASK_ROOT"/Resources/*.txt "$TASK_ROOT"/Resources/*.json "$TASK_APP/Contents/Resources/"
"$TASK_SWIFTC" -sdk "$TASK_SDK" "$TASK_ROOT/scripts/icon.swift" -o "$TASK_BUILD/icon-maker"
"$TASK_BUILD/icon-maker" "$TASK_BUILD/AppIcon.iconset"
/usr/bin/iconutil -c icns "$TASK_BUILD/AppIcon.iconset" -o "$TASK_APP/Contents/Resources/AppIcon.icns"
/usr/bin/codesign --force --sign - "$TASK_APP"
echo "BUILD_OK: $TASK_APP"
