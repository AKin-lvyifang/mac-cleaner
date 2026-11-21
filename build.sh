#!/bin/zsh
# 编译 → 打包成 /Applications/Mac Cleaner.app → 设为开机自启并立即启动
set -e
cd "$(dirname "$0")"
APP="/Applications/Mac Cleaner.app"
LABEL="io.github.maccleaner"
PLIST="$HOME/Library/LaunchAgents/$LABEL.plist"

mkdir -p build
swiftc -O MacCleaner.swift -o build/MacCleaner

# 图标：icon.swift 画 1024 图 → 各尺寸 → icns
swift icon.swift build/icon.png
rm -rf build/AppIcon.iconset && mkdir build/AppIcon.iconset
for s in 16 32 128 256 512; do
  sips -z $s $s build/icon.png --out build/AppIcon.iconset/icon_${s}x${s}.png >/dev/null
  sips -z $((s*2)) $((s*2)) build/icon.png --out build/AppIcon.iconset/icon_${s}x${s}@2x.png >/dev/null
done
iconutil -c icns build/AppIcon.iconset -o build/AppIcon.icns

launchctl bootout "gui/$(id -u)/$LABEL" 2>/dev/null || true
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp build/AppIcon.icns "$APP/Contents/Resources/"
cp build/MacCleaner "$APP/Contents/MacOS/MacCleaner"
cat > "$APP/Contents/Info.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleName</key><string>Mac Cleaner</string>
  <key>CFBundleIdentifier</key><string>$LABEL</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>CFBundleExecutable</key><string>MacCleaner</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>1.0</string>
  <key>LSUIElement</key><true/>
  <key>LSMinimumSystemVersion</key><string>13.0</string>
</dict></plist>
EOF
codesign --force -s - "$APP"

cat > "$PLIST" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>Label</key><string>$LABEL</string>
  <key>ProgramArguments</key><array><string>$APP/Contents/MacOS/MacCleaner</string></array>
  <key>RunAtLoad</key><true/>
  <key>ProcessType</key><string>Interactive</string>
</dict></plist>
EOF
launchctl bootstrap "gui/$(id -u)" "$PLIST"
echo "已安装并启动：$APP"
