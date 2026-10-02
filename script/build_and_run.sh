#!/bin/zsh
set -euo pipefail
PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
cd "$PROJECT_DIR"
BUILD_DIR="$HOME/Library/Caches/DriveExplorerBuild"
for EXECUTABLE_PATH in "$PROJECT_DIR/dist/DriveExplorer.app/Contents/MacOS/DriveExplorer" "$BUILD_DIR/DriveExplorer.app/Contents/MacOS/DriveExplorer" "$PROJECT_DIR/dist/DriveTrace.app/Contents/MacOS/DriveTrace" "$BUILD_DIR/DriveTrace.app/Contents/MacOS/DriveTrace"; do
  if pgrep -f "$EXECUTABLE_PATH" >/dev/null; then
    pkill -f "$EXECUTABLE_PATH"
  fi
done
"$PROJECT_DIR/script/build.sh"
open -n "$BUILD_DIR/DriveTrace.app"
