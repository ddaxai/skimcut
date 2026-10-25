#!/usr/bin/env bash
# 仅 macOS：swift build -c release → build/SkimCut.app → ad-hoc 签名。
set -euo pipefail
cd "$(dirname "$0")/.."

if [[ "$(uname -s)" != "Darwin" ]]; then
  echo "bundle-app.sh 只能在 macOS 上运行" >&2
  exit 1
fi

swift build -c release --product SkimCutApp
BIN_DIR="$(swift build -c release --show-bin-path)"

APP="build/SkimCut.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN_DIR/SkimCutApp" "$APP/Contents/MacOS/SkimCutApp"
cp Resources/Info.plist "$APP/Contents/Info.plist"

# App 图标：Resources/AppIcon.png（1024×1024）→ 各种尺寸 → AppIcon.icns。
ICONSET="$(mktemp -d)/AppIcon.iconset"
mkdir -p "$ICONSET"
for size in 16 32 128 256 512; do
  sips -z $size $size Resources/AppIcon.png --out "$ICONSET/icon_${size}x${size}.png" >/dev/null
  sips -z $((size * 2)) $((size * 2)) Resources/AppIcon.png --out "$ICONSET/icon_${size}x${size}@2x.png" >/dev/null
done
iconutil -c icns "$ICONSET" -o "$APP/Contents/Resources/AppIcon.icns"
rm -rf "$(dirname "$ICONSET")"

# SwiftPM 生成的资源包（以后如果有）。
for bundle in "$BIN_DIR"/*.bundle; do
  [[ -e "$bundle" ]] && cp -R "$bundle" "$APP/Contents/Resources/"
done

# 构建号 = 提交数，方便确认拿到的是哪一版。
if BUILD=$(git rev-list --count HEAD 2>/dev/null); then
  /usr/libexec/PlistBuddy -c "Set :CFBundleVersion $BUILD" "$APP/Contents/Info.plist"
fi
plutil -lint "$APP/Contents/Info.plist"

codesign --force --sign - --timestamp=none "$APP"
codesign --verify --strict --verbose=2 "$APP"

echo "已生成 $APP"
