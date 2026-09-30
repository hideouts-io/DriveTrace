#!/bin/zsh
set -euo pipefail
PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
cd "$PROJECT_DIR"
BUILD_DIR="$HOME/Library/Caches/DriveExplorerBuild"
if pgrep -f "$BUILD_DIR/DriveExplorer.app/Contents/MacOS/DriveExplorer" >/dev/null; then
  print -u2 "Quit Drive Explorer before packaging, or use script/build_and_run.sh to rebuild and relaunch."
  exit 1
fi
swift build -c release --product DriveExplorer --arch arm64 --arch x86_64 --scratch-path "$BUILD_DIR"
BINARY_DIR="$(swift build -c release --product DriveExplorer --arch arm64 --arch x86_64 --scratch-path "$BUILD_DIR" --show-bin-path)"
PACKAGE_DIR="$(mktemp -d "$BUILD_DIR/package.XXXXXX")"
trap 'rm -rf "$PACKAGE_DIR"' EXIT
APP_DIR="$PACKAGE_DIR/DriveExplorer.app"
mkdir -p "$APP_DIR/Contents/MacOS" "$APP_DIR/Contents/Resources"
cp "$BINARY_DIR/DriveExplorer" "$APP_DIR/Contents/MacOS/DriveExplorer"
ditto "$BINARY_DIR/DriveMonitorSwift_DriveExplorer.bundle" "$APP_DIR/Contents/Resources/DriveMonitorSwift_DriveExplorer.bundle"
cp "$PROJECT_DIR/LICENSE" "$APP_DIR/Contents/Resources/LICENSE"
cp "$PROJECT_DIR/assets/drive-explorer-dock.icns" "$APP_DIR/Contents/Resources/DriveExplorer.icns"
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
"$PROJECT_DIR/script/verify_bundle.sh" "$APP_DIR"
rm -rf "$BUILD_DIR/DriveExplorer.app"
mv "$APP_DIR" "$BUILD_DIR/DriveExplorer.app"
APP_DIR="$BUILD_DIR/DriveExplorer.app"
mkdir -p "$PROJECT_DIR/dist"
if [[ -d "$PROJECT_DIR/dist/DriveExplorer.app" && ! -L "$PROJECT_DIR/dist/DriveExplorer.app" ]]; then
  mv "$PROJECT_DIR/dist/DriveExplorer.app" "$BUILD_DIR/previous-DriveExplorer-$(date +%s).app"
fi
ln -sfn "$APP_DIR" "$PROJECT_DIR/dist/DriveExplorer.app"
ditto -c -k --keepParent --norsrc --noextattr "$APP_DIR" "$PROJECT_DIR/dist/DriveExplorer.zip"
ditto -x -k "$PROJECT_DIR/dist/DriveExplorer.zip" "$PACKAGE_DIR/extracted"
"$PROJECT_DIR/script/verify_bundle.sh" "$PACKAGE_DIR/extracted/DriveExplorer.app"
(cd "$PROJECT_DIR/dist" && shasum -a 256 DriveExplorer.zip > SHA256SUMS)
cat "$PROJECT_DIR/dist/SHA256SUMS"
print "Packaged universal ad-hoc preview. Developer ID signing and notarization are not performed."
