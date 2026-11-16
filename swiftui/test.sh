#!/bin/bash
# Runs language/data regressions in a temporary app bundle with its own preferences.
set -euo pipefail
source_dir="$(cd "$(dirname "$0")" && pwd)"
test_dir="$(mktemp -d "${TMPDIR:-/tmp}/tabtapcap-language-tests.XXXXXX")"
trap 'rm -rf "$test_dir"' EXIT
app="$test_dir/LanguageTests.app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
cat > "$app/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleIdentifier</key><string>app.tabtapcap.language-tests</string>
<key>CFBundleExecutable</key><string>LanguageTests</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleDevelopmentRegion</key><string>ja</string>
</dict></plist>
PLIST
cp -R "$source_dir/Resources/" "$app/Contents/Resources/"
xcrun swiftc -swift-version 6 -warnings-as-errors -target arm64-apple-macosx26.0 \
    -module-cache-path "$test_dir/module-cache" \
    "$source_dir/Sources/Localization.swift" "$source_dir/Sources/RecordingLibrary.swift" \
    "$source_dir/Tests/LanguageTests.swift" -o "$app/Contents/MacOS/LanguageTests"
"$app/Contents/MacOS/LanguageTests"

xcrun swiftc -swift-version 6 -warnings-as-errors -target arm64-apple-macosx26.0 \
    -module-cache-path "$test_dir/module-cache" \
    "$source_dir/Sources/Localization.swift" "$source_dir/Sources/RecordingLibrary.swift" \
    "$source_dir/Sources/AACFileWriter.swift" "$source_dir/Tests/AudioEncodingTests.swift" \
    -o "$test_dir/AudioEncodingTests"
"$test_dir/AudioEncodingTests"
"$test_dir/AudioEncodingTests" --write-failure

model_sources=()
for source in "$source_dir"/Sources/*.swift; do
    if [[ "$(basename "$source")" != "TabTapCapApp.swift" ]]; then
        model_sources+=("$source")
    fi
done
xcrun swiftc -O -swift-version 6 -warnings-as-errors -target arm64-apple-macosx26.0 \
    -module-cache-path "$test_dir/module-cache" "${model_sources[@]}" \
    "$source_dir/Tests/MemoryRegressionTests.swift" "$source_dir/Tests/OptimizationRegressionTests.swift" -o "$test_dir/MemoryRegressionTests"
"$test_dir/MemoryRegressionTests"
