#!/bin/bash
# Builds and signs the standalone app using Xcode's Swift compiler.
set -euo pipefail

source_dir="$(cd "$(dirname "$0")" && pwd)"
output_dir="${1:-$source_dir/dist}"
app="$output_dir/TabTapCap.app"
mkdir -p "$app/Contents/Resources" "$app/Contents/MacOS" "$output_dir/module-cache"
cp "$source_dir/Info.plist" "$app/Contents/Info.plist"
cp -R "$source_dir/Resources/" "$app/Contents/Resources/"
xcrun swiftc -O -swift-version 6 -warnings-as-errors -target arm64-apple-macosx26.0 \
  -module-cache-path "$output_dir/module-cache" \
  "$source_dir"/Sources/*.swift -o "$app/Contents/MacOS/TabTapCap"
codesign --force --sign - "$app"
codesign --verify --strict "$app"
printf '%s\n' "$app"
