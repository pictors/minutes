#!/bin/zsh
# 採用済み B1 のアイコン原画を macOS の全サイズに変換する（描画内容は変更しない）。
set -euo pipefail
cd "$(dirname "$0")/.."
ICON_SOURCE="assets/brand/minutes-b1/app-icon.png"
ICONSET=".build/brand/Minutes.iconset"
mkdir -p "$ICONSET"
for size in 16 32 128 256 512; do
  sips -z "$size" "$size" "$ICON_SOURCE" --out "$ICONSET/icon_${size}x${size}.png" >/dev/null
  retina_size=$((size * 2))
  sips -z "$retina_size" "$retina_size" "$ICON_SOURCE" --out "$ICONSET/icon_${size}x${size}@2x.png" >/dev/null
done
iconutil -c icns "$ICONSET" -o .build/brand/AppIcon.icns
echo "built: .build/brand/AppIcon.icns"
