#!/bin/zsh
set -euo pipefail
if [[ "$#" != 1 ]]; then
  print -u2 "Usage: script/verify_bundle.sh /absolute/path/DriveExplorer.app"
  exit 1
fi
PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
APP_DIR="$1"
codesign --verify --deep --strict --all-architectures "$APP_DIR"
lipo "$APP_DIR/Contents/MacOS/DriveExplorer" -verify_arch arm64
lipo "$APP_DIR/Contents/MacOS/DriveExplorer" -verify_arch x86_64
if [[ "$(plutil -extract CFBundleIdentifier raw "$APP_DIR/Contents/Info.plist")" != "local.driveexplorer" ]]; then
  print -u2 "Unexpected bundle identity. Rebuild from this project's packaging script."; exit 1
fi
if [[ "$(plutil -extract LSMinimumSystemVersion raw "$APP_DIR/Contents/Info.plist")" != "14.0" ]]; then
  print -u2 "Unexpected minimum macOS version. Review Package.swift and the packaged Info.plist."; exit 1
fi
if [[ ! -s "$APP_DIR/Contents/Resources/DriveExplorer.icns" ]]; then
  print -u2 "Packaged icon is missing or empty. Rebuild with script/build.sh."; exit 1
fi
cmp "$PROJECT_DIR/assets/drive-explorer-dock.icns" "$APP_DIR/Contents/Resources/DriveExplorer.icns"
cmp "$PROJECT_DIR/LICENSE" "$APP_DIR/Contents/Resources/LICENSE"
cmp "$PROJECT_DIR/Sources/DriveExplorer/Resources/drive-explorer-logo.png" "$APP_DIR/Contents/Resources/DriveMonitorSwift_DriveExplorer.bundle/Contents/Resources/drive-explorer-logo.png"
print "Verified both architectures, signature, bundle identity, minimum OS, icon, canonical logo and license."
