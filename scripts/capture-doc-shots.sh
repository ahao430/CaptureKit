#!/bin/bash
# 文档截图流水线：用 --demo-* 参数驱动真实 UI，逐窗口全屏截图后按坐标裁剪。
# 用法: scripts/capture-doc-shots.sh <app路径> <输出目录>
set -euo pipefail
APP="${1:?用法: capture-doc-shots.sh <app路径> <输出目录>}"
OUT="${2:?缺少输出目录}"
mkdir -p "$OUT"

LIST=$(mktemp)
trap 'rm -f "$LIST"' EXIT

wait_window() {
  local pattern="$1" retries="${2:-40}"
  for _ in $(seq 1 "$retries"); do
    swift "$(dirname "$0")/list-windows.swift" > "$LIST" 2>/dev/null || true
    if grep -q "$pattern" "$LIST"; then return 0; fi
    sleep 0.5
  done
  echo "错误：窗口 '$pattern' 未出现" >&2
  return 1
}

# 全屏截图 → 按 CG 坐标（原点左上）裁出窗口区
shot_window() {
  local pattern="$1" name="$2" crop_w="$3" crop_h="$4"
  wait_window "$pattern"
  local line
  line=$(grep "$pattern" "$LIST" | head -1)
  local x y
  x=$(echo "$line" | cut -f3 | cut -d, -f1)
  y=$(echo "$line" | cut -f3 | cut -d, -f2)
  screencapture -x "$OUT/_full_tmp.png"
  ~/.gpt-image-skill/.venv/bin/python - "$OUT/_full_tmp.png" "$OUT/$name.png" "$x" "$y" "$crop_w" "$crop_h" <<'PYEOF'
import sys
from PIL import Image
src, dst, x, y, w, h = sys.argv[1:]
im = Image.open(src)
scale = im.width / 1440  # 主屏逻辑宽 → 像素
box = (int(float(x)*scale), int(float(y)*scale),
       int((float(x)+float(w))*scale), int((float(y)+float(h))*scale))
im.crop(box).save(dst)
print(f"{dst}: {box}")
PYEOF
}

killall CaptureKit 2>/dev/null || true; sleep 1

echo "==> 1/5 编辑器（标注演示）"
open "$APP" --args --demo-editor
shot_window "编辑器" editor 1240 800
killall CaptureKit; sleep 1

echo "==> 2/5 历史窗口"
open "$APP" --args --demo-history
shot_window "历史" history 1240 800
killall CaptureKit; sleep 1

echo "==> 3/5 设置窗口"
open "$APP" --args --demo-settings
shot_window "设置" settings 1240 800
killall CaptureKit; sleep 1

echo "==> 4/5 菜单栏 Popover"
open "$APP" --args --demo-popover
shot_window "NSStatusBar" popover 380 420 || true
killall CaptureKit; sleep 1

echo "==> 5/5 选区遮罩（全屏，不裁剪）"
open "$APP" --args --demo-overlay
wait_window "CaptureKit" 60 || true
sleep 1
screencapture -x "$OUT/overlay.png"
killall CaptureKit 2>/dev/null || true

rm -f "$OUT/_full_tmp.png"
echo "==> 完成"; ls -la "$OUT"
