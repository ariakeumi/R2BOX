#!/bin/zsh
# 构建 R2BOX.app（Debug 或 Release），并可选直接打开
# 用法: scripts/run.sh [--release] [--open]
set -e
cd "$(dirname "$0")/.."

CONFIG="debug"
OPEN=0
for arg in "$@"; do
  case "$arg" in
    --release) CONFIG="release" ;;
    --open) OPEN=1 ;;
  esac
done

echo "==> swift build -c $CONFIG"
swift build -c "$CONFIG"

BIN=".build/$CONFIG/R2BOXApp"
APP="build/R2BOX.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/R2BOX"
[ -f Resources/AppIcon.icns ] && cp Resources/AppIcon.icns "$APP/Contents/Resources/"

cat > "$APP/Contents/Info.plist" << 'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key>              <string>R2BOX</string>
    <key>CFBundleDisplayName</key>       <string>R2BOX</string>
    <key>CFBundleIdentifier</key>        <string>dev.r2box.app</string>
    <key>CFBundleExecutable</key>        <string>R2BOX</string>
    <key>CFBundleIconFile</key>          <string>AppIcon</string>
    <key>CFBundlePackageType</key>       <string>APPL</string>
    <key>CFBundleShortVersionString</key><string>0.1.0</string>
    <key>CFBundleVersion</key>           <string>1</string>
    <key>CFBundleInfoDictionaryVersion</key> <string>6.0</string>
    <key>LSMinimumSystemVersion</key>    <string>14.0</string>
    <key>NSPrincipalClass</key>          <string>NSApplication</string>
    <key>NSHighResolutionCapable</key>   <true/>
    <key>NSHumanReadableCopyright</key>  <string>Copyright © 2026. MIT License.</string>
    <key>LSApplicationCategoryType</key> <string>public.app-category.utilities</string>
</dict>
</plist>
PLIST

codesign --force -s - "$APP" 2>/dev/null || true
# 刷新 LaunchServices 对该 bundle 的图标缓存
touch "$APP"
/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f "$APP" 2>/dev/null || true
echo "==> $APP 构建完成"

if [[ $OPEN == 1 ]]; then
  open "$APP"
fi
