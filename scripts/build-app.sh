#!/bin/zsh
set -euo pipefail
PROJECT_ROOT="${0:A:h:h}"
cd "$PROJECT_ROOT"
swift build -c release
APP_PATH="${APP_OUTPUT_PATH:-$PROJECT_ROOT/dist/Kimi Usage.app}"
WATCHER_PATH="$APP_PATH/Contents/Library/LoginItems/Kimi Usage Watcher.app"
mkdir -p "$APP_PATH/Contents/MacOS" "$APP_PATH/Contents/Resources" "$WATCHER_PATH/Contents/MacOS"
cp .build/release/KimiUsage "$APP_PATH/Contents/MacOS/KimiUsage"
strip -S -x "$APP_PATH/Contents/MacOS/KimiUsage"
cp .build/release/KimiUsageWatcher "$WATCHER_PATH/Contents/MacOS/KimiUsageWatcher"
strip -S -x "$WATCHER_PATH/Contents/MacOS/KimiUsageWatcher"
cp LICENSE "$APP_PATH/Contents/Resources/LICENSE.txt"
cp THIRD_PARTY_LICENSES/Unicode-LICENSE.txt "$APP_PATH/Contents/Resources/Unicode-LICENSE.txt"
cat > "$APP_PATH/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleName</key><string>Kimi Usage</string>
<key>CFBundleDisplayName</key><string>Kimi 额度</string>
<key>CFBundleExecutable</key><string>KimiUsage</string>
<key>CFBundleIdentifier</key><string>com.yokinri.kimi-usage</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleShortVersionString</key><string>0.2.1</string>
<key>CFBundleVersion</key><string>3</string>
<key>LSMinimumSystemVersion</key><string>13.0</string>
<key>LSUIElement</key><true/>
<key>NSHighResolutionCapable</key><true/>
</dict></plist>
PLIST
cat > "$WATCHER_PATH/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleName</key><string>Kimi Usage Watcher</string>
<key>CFBundleDisplayName</key><string>Kimi 额度自动跟随</string>
<key>CFBundleExecutable</key><string>KimiUsageWatcher</string>
<key>CFBundleIdentifier</key><string>com.yokinri.kimi-usage.watcher</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleShortVersionString</key><string>0.2.1</string>
<key>CFBundleVersion</key><string>3</string>
<key>LSMinimumSystemVersion</key><string>13.0</string>
<key>LSBackgroundOnly</key><true/>
</dict></plist>
PLIST
codesign --force --sign "${CODESIGN_IDENTITY:--}" "$WATCHER_PATH"
codesign --force --sign "${CODESIGN_IDENTITY:--}" "$APP_PATH"
codesign --verify --deep --strict "$APP_PATH"
print -r -- "Built: $APP_PATH"
