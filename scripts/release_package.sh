#!/bin/zsh
# 发布打包流水线：
#   1. 复用 build_app.sh 构建 + Developer ID 签名；
#   2. 可选公证：设置 ANISE_RECORDER_NOTARY_PROFILE（notarytool
#      store-credentials 建立的钥匙串配置名）后自动提交公证并 staple；
#      未设置时跳过公证并在结论中注明缺口；
#   3. 产物：zip（ditto）与 DMG（hdiutil），落在 dist/；
#   4. Gatekeeper 评估输出（spctl）供发布检查引用。
#
# 用法: scripts/release_package.sh
# 产物: dist/八角录屏-<版本>.zip、dist/八角录屏-<版本>.dmg
set -euo pipefail

cd "$(dirname "$0")/.."

# 版本号以仓库源文件为准（构建产物是旧版本时也能读对）。
VERSION=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' \
  Resources/Info.plist 2>/dev/null || echo "0.0.0")
mkdir -p dist
echo "== 1/5 构建 =="
./scripts/build_app.sh

echo "== 2/5 Developer ID 签名校验 =="
IDENTITY=$(security find-identity -v -p codesigning 2>/dev/null \
  | awk -F '"' '/Developer ID Application/ { print $2; exit }')
if [[ -z "$IDENTITY" ]]; then
  echo "缺口：钥匙串无 Developer ID Application 证书。"
  exit 1
fi
echo "签名身份: $IDENTITY"
codesign --force --options runtime --timestamp \
  --entitlements Resources/AniseRecorder.entitlements \
  --sign "$IDENTITY" 八角录屏.app
codesign --verify --strict 八角录屏.app && echo "codesign verify: OK"

echo "== 3/5 公证（可选）==="
if [[ -n "${ANISE_RECORDER_NOTARY_PROFILE:-}" ]]; then
  ZIP_FOR_NOTARY="dist/八角录屏-$VERSION-notarize.zip"
  ditto -c -k --keepParent 八角录屏.app "$ZIP_FOR_NOTARY"
  xcrun notarytool submit "$ZIP_FOR_NOTARY" \
    --keychain-profile "$ANISE_RECORDER_NOTARY_PROFILE" --wait
  xcrun stapler staple 八角录屏.app
  xcrun stapler validate 八角录屏.app
  echo "公证 + staple: OK"
else
  echo "缺口：未设置 ANISE_RECORDER_NOTARY_PROFILE，公证与 staple 跳过。"
  echo "维护者需先执行一次 xcrun notarytool store-credentials <配置名>，"
  echo "（凭据只进本机钥匙串，不进仓库）"
fi

echo "== 4/5 Gatekeeper 评估（spctl）=="
spctl -a -t exec -vv 八角录屏.app || true

echo "== 5/5 产物打包 =="
rm -f "dist/八角录屏-$VERSION.zip" "dist/八角录屏-$VERSION.dmg"
ditto -c -k --keepParent 八角录屏.app "dist/八角录屏-$VERSION.zip"
hdiutil create -volname "八角录屏 $VERSION" -srcfolder 八角录屏.app \
  -ov -format UDZO "dist/八角录屏-$VERSION.dmg" >/dev/null
ls -lh dist/ | grep -v "^total"
echo "== 演练打包完成：dist/八角录屏-$VERSION.{zip,dmg} =="
