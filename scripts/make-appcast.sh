#!/bin/bash
# 生成 Sparkle appcast.xml（ADR-029）：
#   用官方 generate_appcast 对 zip 更新包做 EdDSA 签名并输出 feed。
# feed 固定作为 Release 附件发布，应用内 SUFeedURL 指向
#   https://github.com/OWNER/REPO/releases/latest/download/appcast.xml
#
# 用法: scripts/make-appcast.sh <archives-dir> <download-url-prefix> [私钥文件]
#   私钥文件缺省时从 stdin 读取（CI：echo "$SPARKLE_PRIVATE_KEY" | ...）。
#   也可用环境变量 SPARKLE_TOOLS_DIR 指定已解压的 Sparkle 发行包（含 bin/）。
set -euo pipefail

DIR="${1:?用法: make-appcast.sh <archives-dir> <download-url-prefix> [私钥文件]}"
PREFIX="${2:?缺少 download-url-prefix（形如 https://github.com/OWNER/REPO/releases/download/v1.0.0）}"
KEY_FILE="${3:-}"

# generate_appcast 把前缀当作目录基址：不以 / 结尾会丢弃最后一段（实测），统一补齐
case "$PREFIX" in */) ;; *) PREFIX="$PREFIX/" ;; esac
# 工具在 cd 后会按 CWD 重解析相对路径（CI 实测翻倍错误），一律转绝对
DIR="$(cd "$DIR" && pwd)"

SPARKLE_VERSION="2.10.1"
SPARKLE_DIST_URL="https://github.com/sparkle-project/Sparkle/releases/download/${SPARKLE_VERSION}/Sparkle-${SPARKLE_VERSION}.tar.xz"
TOOLS="${SPARKLE_TOOLS_DIR:-$HOME/.cache/sparkle-tools}"
TOOL="$TOOLS/bin/generate_appcast"

# 1. 获取 generate_appcast（缓存，只取 bin/）
if [ ! -x "$TOOL" ]; then
  echo "==> 下载 Sparkle 工具 $SPARKLE_VERSION"
  mkdir -p "$TOOLS"
  curl -fsSL "$SPARKLE_DIST_URL" | tar -xJ -C "$TOOLS" bin
  chmod +x "$TOOLS/bin/"*
fi

cd "$DIR"

# 2. 签名生成 appcast（enclosure URL 前缀指向 Release 附件）
if [ -n "$KEY_FILE" ]; then
  "$TOOL" --ed-key-file "$KEY_FILE" --download-url-prefix "$PREFIX" "$DIR"
else
  echo "${SPARKLE_PRIVATE_KEY:?需要第 3 参数私钥文件或 SPARKLE_PRIVATE_KEY 环境变量}" \
    | "$TOOL" --ed-key-file - --download-url-prefix "$PREFIX" "$DIR"
fi

# 3. 自检：appcast.xml 存在且含签名与绝对 URL
APPCAST="$DIR/appcast.xml"
[ -f "$APPCAST" ] || { echo "错误：未生成 appcast.xml"; exit 1; }
grep -q "sparkle:edSignature" "$APPCAST" || { echo "错误：appcast 缺少 EdDSA 签名"; exit 1; }
grep -q "releases/download" "$APPCAST" || { echo "错误：enclosure URL 不是绝对 Release 地址"; exit 1; }
echo "完成：$APPCAST"
