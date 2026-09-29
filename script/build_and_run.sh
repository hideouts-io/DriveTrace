#!/bin/zsh
set -euo pipefail
PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
cd "$PROJECT_DIR"
BUILD_DIR="$HOME/Library/Caches/DriveExplorerBuild"
for EXECUTABLE_PATH in "$PROJECT_DIR/dist/DriveExplorer.app/Contents/MacOS/DriveExplorer" "$BUILD_DIR/DriveExplorer.app/Contents/MacOS/DriveExplorer"; do
  if pgrep -f "$EXECUTABLE_PATH" >/dev/null; then
    pkill -f "$EXECUTABLE_PATH"
  fi
done
swift build -c release --scratch-path "$BUILD_DIR"
APP_DIR="$BUILD_DIR/DriveExplorer.app"
mkdir -p "$APP_DIR/Contents/MacOS" "$APP_DIR/Contents/Resources"
cp "$BUILD_DIR/release/DriveExplorer" "$APP_DIR/Contents/MacOS/DriveExplorer"
ditto "$BUILD_DIR/release/DriveMonitorSwift_DriveExplorer.bundle" "$APP_DIR/Contents/Resources/DriveMonitorSwift_DriveExplorer.bundle"
cp "$PROJECT_DIR/LICENSE" "$APP_DIR/Contents/Resources/LICENSE"
swift script/make_icon.swift "$PROJECT_DIR/Sources/DriveExplorer/Resources/drive-explorer-logo.png" "$BUILD_DIR/DriveExplorer.iconset"
iconutil -c icns "$BUILD_DIR/DriveExplorer.iconset" -o "$APP_DIR/Contents/Resources/DriveExplorer.icns"
cat > "$APP_DIR/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleExecutable</key><string>DriveExplorer</string>
<key>CFBundleIdentifier</key><string>local.driveexplorer</string>
<key>CFBundleName</key><string>Drive Explorer</string>
<key>CFBundleDisplayName</key><string>Drive Explorer</string>
<key>CFBundleIconFile</key><string>DriveExplorer</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleShortVersionString</key><string>0.1.0</string>
<key>CFBundleVersion</key><string>1</string>
<key>NSHumanReadableCopyright</key><string>Copyright © 2026 hideouts-io. MIT License.</string>
<key>LSMinimumSystemVersion</key><string>14.0</string>
<key>NSHighResolutionCapable</key><true/>
<key>NSPrincipalClass</key><string>NSApplication</string>
</dict></plist>
PLIST
xattr -cr "$APP_DIR"
codesign --force --sign - "$APP_DIR"
codesign --verify --deep --strict "$APP_DIR"
mkdir -p "$PROJECT_DIR/dist"
if [[ -d "$PROJECT_DIR/dist/DriveExplorer.app" && ! -L "$PROJECT_DIR/dist/DriveExplorer.app" ]]; then
  mv "$PROJECT_DIR/dist/DriveExplorer.app" "$BUILD_DIR/previous-DriveExplorer-$(date +%s).app"
fi
ln -sfn "$APP_DIR" "$PROJECT_DIR/dist/DriveExplorer.app"
ditto -c -k --keepParent --norsrc --noextattr "$APP_DIR" "$PROJECT_DIR/dist/DriveExplorer.zip"
open -n "$APP_DIR"
