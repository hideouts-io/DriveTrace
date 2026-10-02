#!/bin/zsh
set -euo pipefail
if [[ "$#" != 1 ]]; then
  print -u2 "Usage: script/verify_bundle.sh /absolute/path/DriveTrace.app"
  exit 1
fi
PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
APP_DIR="$1"
codesign --verify --deep --strict --all-architectures "$APP_DIR"
lipo "$APP_DIR/Contents/MacOS/DriveTrace" -verify_arch arm64
lipo "$APP_DIR/Contents/MacOS/DriveTrace" -verify_arch x86_64
for PRODUCT_KEY in CFBundleExecutable CFBundleName CFBundleDisplayName CFBundleIconFile; do
  if [[ "$(plutil -extract "$PRODUCT_KEY" raw "$APP_DIR/Contents/Info.plist")" != "DriveTrace" ]]; then
    print -u2 "Unexpected $PRODUCT_KEY. Rebuild to package the canonical DriveTrace name."; exit 1
  fi
done
if [[ "$(plutil -extract CFBundleIdentifier raw "$APP_DIR/Contents/Info.plist")" != "local.driveexplorer" ]]; then
  print -u2 "Unexpected bundle identity. Rebuild from this project's packaging script."; exit 1
fi
if [[ "$(plutil -extract LSMinimumSystemVersion raw "$APP_DIR/Contents/Info.plist")" != "14.0" ]]; then
  print -u2 "Unexpected minimum macOS version. Review Package.swift and the packaged Info.plist."; exit 1
fi
if [[ ! -s "$APP_DIR/Contents/Resources/DriveTrace.icns" ]]; then
  print -u2 "Packaged icon is missing or empty. Rebuild with script/build.sh."; exit 1
fi
cmp "$PROJECT_DIR/assets/drivetrace.icns" "$APP_DIR/Contents/Resources/DriveTrace.icns"
cmp "$PROJECT_DIR/LICENSE" "$APP_DIR/Contents/Resources/LICENSE"
cmp "$PROJECT_DIR/Sources/DriveTrace/Resources/drivetrace-icon.png" "$APP_DIR/Contents/Resources/DriveTrace_DriveTrace.bundle/Contents/Resources/drivetrace-icon.png"
print "Verified both architectures, signature, bundle identity, minimum OS, icon, canonical logo and license."
