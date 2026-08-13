#!/bin/zsh
set -euo pipefail
export PATH="/usr/bin:/bin:/usr/sbin:/sbin"
rehash

PROJECT_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$PROJECT_ROOT"

required=(
  Package.swift
  Resources/Info.plist
  Sources/OneImageCompare/AppMain.swift
  Sources/OneImageCompare/ContentView.swift
  Sources/OneImageCompare/PhotoStore.swift
  Sources/OneImageCompare/ImagePipeline.swift
  Sources/OneImageCompare/ExportService.swift
  scripts/build_dmg.sh
)
for path in "${required[@]}"; do
  [[ -f "$path" ]] || { echo "Missing $path" >&2; exit 1; }
done

[[ -x /usr/bin/plutil ]] || { echo "Missing /usr/bin/plutil" >&2; exit 1; }
/usr/bin/plutil -lint Resources/Info.plist
/usr/bin/swift package dump-package >/dev/null
/usr/bin/swift build -c debug --arch arm64
BIN_PATH="$(/usr/bin/swift build -c debug --arch arm64 --show-bin-path)"
[[ -x "$BIN_PATH/OneImageCompare" ]] || { echo "Missing arm64 executable" >&2; exit 1; }
ARCHS="$(/usr/bin/file "$BIN_PATH/OneImageCompare")"
[[ "$ARCHS" == *"arm64"* ]] || { echo "Executable is not arm64: $ARCHS" >&2; exit 1; }
echo "Project structure and arm64 debug build verified."
