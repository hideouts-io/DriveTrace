#!/bin/zsh
set -euo pipefail
PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
cd "$PROJECT_DIR"
swift test --scratch-path "$HOME/Library/Caches/DriveExplorerBuild"
