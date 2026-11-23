#!/bin/bash
# CaptureKit 发布构建（ADR-028/029）：
#   Universal Binary → 证书签名（身份缺失时回退 ad-hoc）→ DMG（拖拽安装）→ Sparkle 更新 zip
# 产物资产名固定（CaptureKit.dmg / CaptureKit.zip），保证
#   https://github.com/OWNER/REPO/releases/latest/download/CaptureKit.dmg
# 与 appcast 的 enclosure URL 规则不随版本变化。
#
# 用法: scripts/build-release.sh [版本号] [构建号]
#   版本号缺省取 tag/手动；构建号建议用 CI run number（Sparkle sparkle:version）。
# 环境变量：
#   MACOS_SIGNING_IDENTITY   签名身份名称（默认 CaptureKit Developer）
#   MACOS_SIGNING_REQUIRED=1 找不到签名身份时失败而不回退（发布必须开启）
set -euo pipefail

VERSION="${1:?用法: build-release.sh <版本号> [构建号]}"
BUILD="${2:-1}"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP_NAME="CaptureKit"
DERIVED="$ROOT/build/DerivedData"
OUT="$ROOT/build/release"

cd "$ROOT"

echo "==> 版本 $VERSION (build $BUILD)"

# 1. 生成工程（保证新增源文件纳入构建）
xcodegen generate

# 2. Universal Release 构建（无 Developer ID：ad-hoc 签名由 Xcode 自动完成）
xcodebuild -project CaptureKit.xcodeproj -scheme CaptureKit \
  -configuration Release -destination 'generic/platform=macOS' \
  -derivedDataPath "$DERIVED" \
  ARCHS="arm64 x86_64" ONLY_ACTIVE_ARCH=NO \
  MARKETING_VERSION="$VERSION" CURRENT_PROJECT_VERSION="$BUILD" \
  build

APP="$DERIVED/Build/Products/Release/$APP_NAME.app"
BIN="$APP/Contents/MacOS/$APP_NAME"

# 3. 校验双架构
echo "==> 架构"
lipo -info "$BIN" | tee /dev/stderr | grep -q "arm64" 
lipo -info "$BIN" | grep -q "x86_64"

# 4. 签名：固定证书身份（MACOS_SIGNING_IDENTITY，ADR-030）。
#    macOS 的 TCC 授权绑定代码签名身份：ad-hoc 每次构建指纹不同，授权留不住。
#    身份检测不要求「受信任」——自签名证书在全新机器上 find-identity -v 为 0，
#    但 codesign 按名称签名不需要信任链（实测）。不能依赖 add-trusted-cert（CI 上会挂起）。
#    MACOS_SIGNING_REQUIRED=1（发布）时找不到身份直接失败，禁止悄悄回退成 ad-hoc 发出去。
echo "==> 签名"
SIGN_IDENTITY="${MACOS_SIGNING_IDENTITY:-CaptureKit Developer}"
SIGNING_REQUIRED="${MACOS_SIGNING_REQUIRED:-0}"
HAS_IDENTITY=0
if security find-identity -p codesigning 2>/dev/null | grep -q "\"$SIGN_IDENTITY\""; then
  HAS_IDENTITY=1
fi
if [ "$HAS_IDENTITY" -eq 1 ]; then
  codesign --force --sign "$SIGN_IDENTITY" --deep "$APP"
else
  if [ "$SIGNING_REQUIRED" = "1" ]; then
    echo "错误：未找到签名身份 '$SIGN_IDENTITY'，且 MACOS_SIGNING_REQUIRED=1，终止。"
    exit 1
  fi
  echo "警告：未找到签名身份 '$SIGN_IDENTITY'，回退 ad-hoc（TCC 授权将无法跨版本保留）"
  SIGN_IDENTITY="-"
  codesign --force --sign - --deep "$APP"
fi
codesign --verify --deep --strict "$APP"

# 签名后硬校验：产物实际签名者必须与预期一致
ACTUAL_AUTHORITY="$(codesign -dvv "$APP" 2>&1 | { grep '^Authority=' || true; } | head -1)"
if [ "$HAS_IDENTITY" -eq 1 ]; then
  if [ "$ACTUAL_AUTHORITY" != "Authority=$SIGN_IDENTITY" ]; then
    echo "错误：签名后校验失败，期望 Authority=$SIGN_IDENTITY，实际 '${ACTUAL_AUTHORITY:-无}'，终止。"
    exit 1
  fi
  echo "签名身份：$ACTUAL_AUTHORITY"
else
  echo "签名身份：ad-hoc"
fi

# 5. 输出目录
rm -rf "$OUT"
mkdir -p "$OUT"

# 6. DMG：App + /Applications 快捷方式（拖拽安装布局）
echo "==> DMG"
STAGING="$OUT/.staging"
rm -rf "$STAGING"
mkdir -p "$STAGING"
cp -R "$APP" "$STAGING/"
ln -s /Applications "$STAGING/Applications"
hdiutil create -volname "$APP_NAME" -srcfolder "$STAGING" -ov -format UDZO "$OUT/$APP_NAME.dmg" -quiet
rm -rf "$STAGING"

# 7. Sparkle 更新包：zip（ditto 保留符号链接与元数据）
echo "==> 更新 zip"
(cd "$(dirname "$APP")" && ditto -c -k --keepParent "$APP_NAME.app" "$OUT/$APP_NAME.zip")

# 8. 汇总（嵌入框架自检）
echo "==> 产物"
[ -d "$APP/Contents/Frameworks/Sparkle.framework" ] || { echo "错误：Sparkle.framework 未嵌入"; exit 1; }
ls -lh "$OUT/$APP_NAME.dmg" "$OUT/$APP_NAME.zip"
echo "完成：$OUT"
