#!/bin/zsh
set -euo pipefail

cd "$(dirname "$0")/.."

if ! command -v swift >/dev/null 2>&1; then
  echo "需要安装 Xcode Command Line Tools。"
  exit 1
fi

swift build -c release --product anise-recorder

APP="八角录屏.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp ".build/release/anise-recorder" "$APP/Contents/MacOS/八角录屏"
# 品牌线描 Logo：打包进 Contents/Resources（Bundle.main 解析）。
# 不用 SwiftPM 资源包——其访问器首选 <App>.app 根目录，会被 codesign
# 以「unsealed contents in bundle root」拒绝；开发期由 Bundle.module
# 走 .build 内的资源包兜底（见 SidebarView.brandMark）。
if [[ -f "Sources/AniseRecorder/Resources/anise-logo.png" ]]; then
  cp "Sources/AniseRecorder/Resources/anise-logo.png" "$APP/Contents/Resources/"
fi
cp "Resources/Info.plist" "$APP/Contents/Info.plist"
if [[ -f "Resources/AppIcon.icns" ]]; then
  cp "Resources/AppIcon.icns" "$APP/Contents/Resources/AppIcon.icns"
fi

SIGN_IDENTITY="${ANISE_RECORDER_SIGN_IDENTITY:-}"
if [[ -z "$SIGN_IDENTITY" ]]; then
  SIGN_IDENTITY="$(
    security find-identity -v -p codesigning 2>/dev/null \
      | awk -F '"' '/Developer ID Application/ { print $2; exit }'
  )"
fi

ENTITLEMENTS="Resources/AniseRecorder.entitlements"
if [[ -n "$SIGN_IDENTITY" ]]; then
  # 公证要求 hardened runtime（Invalid 4000 的直接原因），并带时间戳。
  # 注意不能用 --deep：它会让主程序丢失 runtime 标志（实测 flags=0x0）。
  # hardened runtime 下摄像头/麦克风必须在 entitlements 里显式声明，
  # 否则系统直接拒绝授权（不弹窗、隐私列表里也看不到应用）。
  codesign --force --options runtime --timestamp \
    --entitlements "$ENTITLEMENTS" \
    --sign "$SIGN_IDENTITY" "$APP" >/dev/null
else
  codesign --force --options runtime \
    --entitlements "$ENTITLEMENTS" \
    --sign - "$APP" >/dev/null
fi

echo "Built: $(pwd)/$APP"
