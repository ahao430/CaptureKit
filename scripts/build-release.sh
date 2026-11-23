#!/bin/bash
# CaptureKit 发布构建（ADR-028/029）：
#   Universal Binary → ad-hoc 签名 → DMG（拖拽安装）→ Sparkle 更新 zip
# 产物资产名固定（CaptureKit.dmg / CaptureKit.zip），保证
#   https://github.com/OWNER/REPO/releases/latest/download/CaptureKit.dmg
# 与 appcast 的 enclosure URL 规则不随版本变化。
#
# 用法: scripts/build-release.sh [版本号] [构建号]
#   版本号缺省取 tag/手动；构建号建议用 CI run number（Sparkle sparkle:version）。
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

# 4. 签名：优先稳定身份（MACOS_SIGNING_IDENTITY，TCC 授权跨版本保留），
#    身份缺失时回退 ad-hoc（授权每次构建失效，仅开发用）
echo "==> 签名"
SIGN_IDENTITY="${MACOS_SIGNING_IDENTITY:-CaptureKit Developer}"
if ! security find-identity -v -p codesigning 2>/dev/null | grep -q "$SIGN_IDENTITY"; then
  echo "警告：未找到签名身份 '$SIGN_IDENTITY'，回退 ad-hoc（TCC 授权将无法跨版本保留）"
  SIGN_IDENTITY="-"
fi
codesign --force --sign "$SIGN_IDENTITY" --deep "$APP"
codesign --verify --deep --strict "$APP"

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
