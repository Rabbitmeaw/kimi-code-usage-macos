#!/bin/zsh
set -euo pipefail
PROJECT_ROOT="${0:A:h:h}"
cd "$PROJECT_ROOT"
swift build -c release
APP_PATH="$PROJECT_ROOT/dist/Kimi Usage.app"
mkdir -p "$APP_PATH/Contents/MacOS" "$APP_PATH/Contents/Resources"
cp .build/release/KimiUsage "$APP_PATH/Contents/MacOS/KimiUsage"
strip -S -x "$APP_PATH/Contents/MacOS/KimiUsage"
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
<key>CFBundleShortVersionString</key><string>0.1.0</string>
<key>CFBundleVersion</key><string>1</string>
<key>LSMinimumSystemVersion</key><string>13.0</string>
<key>LSUIElement</key><true/>
<key>NSHighResolutionCapable</key><true/>
</dict></plist>
PLIST
codesign --force --sign "${CODESIGN_IDENTITY:--}" "$APP_PATH"
codesign --verify --deep --strict "$APP_PATH"
print -r -- "Built: $APP_PATH"
