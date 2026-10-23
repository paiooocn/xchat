#!/usr/bin/env bash
# 生成各平台的应用图标。
#
# 图标源 = 侧边栏左上角的品牌标记（lib/ui/widgets/brand_mark.dart 的
# BrandMark.solid）：圆角渐变方块 + 白色「X」。
#
# 依赖：flutter（渲染源图）、ImageMagick（缩放 / 打包）。
# 用法：bash tool/gen_icons.sh
set -euo pipefail
cd "$(dirname "$0")/.."

SRC=tool/icons/brand_1024.png

# ---------------------------------------------------------------- 源图
if [ ! -f "$SRC" ]; then
  echo ">> 渲染品牌标记源图…"
  XCHAT_GEN_ICONS=1 flutter test test/brand_icon_test.dart --update-goldens
fi

resize() { # resize <目标边长> <输出>
  convert "$SRC" -filter Lanczos -resize "${1}x${1}" "$2"
}

# 满幅图标（不透明方图）：平台（iOS / macOS / Windows）会自己套圆角遮罩，
# 所以这里铺满品牌渐变 + 白色「X」，与侧边栏标记同一套几何。
full_icon() { # full_icon <边长> <输出>
  local size=$1 out=$2
  local x1 x2 sw
  x1=$(awk -v s="$size" 'BEGIN{printf "%d", 0.30*s}')
  x2=$(awk -v s="$size" 'BEGIN{printf "%d", 0.70*s}')
  sw=$(awk -v s="$size" 'BEGIN{printf "%d", 0.11*s}')
  convert -size "${size}x${size}" xc: \
    -sparse-color barycentric "0,0 #6E7BFF  ${size},0 #6E7BFF  ${size},${size} #9B5BFF" \
    -draw "stroke white stroke-width $sw stroke-linecap round fill none \
      line $x1,$x1 $x2,$x2 line $x2,$x1 $x1,$x2" \
    -alpha off "$out"
}

# ---------------------------------------------------------------- Android
# 传统图标（各密度 mipmap/ic_launcher.png）
set -- "mdpi 48" "hdpi 72" "xhdpi 96" "xxhdpi 144" "xxxhdpi 192"
for entry in "$@"; do
  set -- $entry
  density=$1
  size=$2
  out="android/app/src/main/res/mipmap-$density/ic_launcher.png"
  resize "$size" "$out"
  echo ">> $out ($size)"
done

# 自适应图标前景（108dp 画布，中间 72dp 的白色「X」）
for entry in "mdpi 1" "hdpi 1.5" "xhdpi 2" "xxhdpi 3" "xxxhdpi 4"; do
  set -- $entry
  density=$1
  factor=$2
  canvas=$(awk -v f="$factor" 'BEGIN{printf "%d", 108*f}')
  box=$(awk -v f="$factor" 'BEGIN{printf "%d", 72*f}')
  offset=$(awk -v c="$canvas" -v b="$box" 'BEGIN{printf "%d", (c-b)/2}')
  x1=$(awk -v o="$offset" -v b="$box" 'BEGIN{printf "%d", o+0.30*b}')
  x2=$(awk -v o="$offset" -v b="$box" 'BEGIN{printf "%d", o+0.70*b}')
  sw=$(awk -v b="$box" 'BEGIN{printf "%d", 0.11*b}')
  out="android/app/src/main/res/mipmap-$density/ic_launcher_foreground.png"
  convert -size "${canvas}x${canvas}" xc:none \
    -draw "stroke white stroke-width $sw stroke-linecap round fill none \
      line $x1,$x1 $x2,$x2 line $x2,$x1 $x1,$x2" \
    "$out"
  echo ">> $out (${canvas}px)"
done

mkdir -p android/app/src/main/res/mipmap-anydpi-v26
cat > android/app/src/main/res/mipmap-anydpi-v26/ic_launcher.xml <<'XML'
<?xml version="1.0" encoding="utf-8"?>
<!-- 自适应图标：渐变底 + 白色「X」（与侧边栏品牌标记一致）。 -->
<adaptive-icon xmlns:android="http://schemas.android.com/apk/res/android">
    <background android:drawable="@drawable/ic_launcher_background" />
    <foreground android:drawable="@mipmap/ic_launcher_foreground" />
</adaptive-icon>
XML

cat > android/app/src/main/res/drawable/ic_launcher_background.xml <<'XML'
<?xml version="1.0" encoding="utf-8"?>
<!-- 品牌渐变底色（与 BrandMark.solid 的线性渐变一致）。 -->
<shape xmlns:android="http://schemas.android.com/apk/res/android"
    android:shape="rectangle">
    <gradient
        android:angle="315"
        android:startColor="#6E7BFF"
        android:endColor="#9B5BFF"
        android:type="linear" />
</shape>
XML

# ---------------------------------------------------------------- macOS
ICONSET=macos/Runner/Assets.xcassets/AppIcon.appiconset
for size in 16 32 64 128 256 512 1024; do
  full_icon "$size" "$ICONSET/app_icon_$size.png"
  echo ">> $ICONSET/app_icon_$size.png ($size)"
done

# ---------------------------------------------------------------- iOS
# iOS 不允许带 alpha：使用满幅不透明版本。
IOS_ICONSET=ios/Runner/Assets.xcassets/AppIcon.appiconset
for entry in "Icon-App-20x20@1x 20" "Icon-App-20x20@2x 40" "Icon-App-20x20@3x 60" \
            "Icon-App-29x29@1x 29" "Icon-App-29x29@2x 58" "Icon-App-29x29@3x 87" \
            "Icon-App-40x40@1x 40" "Icon-App-40x40@2x 80" "Icon-App-40x40@3x 120" \
            "Icon-App-60x60@2x 120" "Icon-App-60x60@3x 180" \
            "Icon-App-76x76@1x 76" "Icon-App-76x76@2x 152" \
            "Icon-App-83.5x83.5@2x 167" "Icon-App-1024x1024@1x 1024"; do
  set -- $entry
  full_icon "$2" "$IOS_ICONSET/$1.png"
  echo ">> $IOS_ICONSET/$1.png ($2)"
done

# ---------------------------------------------------------------- Windows
full_icon 256 .tmp/app_icon_256_full.png
convert .tmp/app_icon_256_full.png \
  -define icon:auto-resize=256,128,64,48,32,16 \
  windows/runner/resources/app_icon.ico
rm -f .tmp/app_icon_256_full.png
echo ">> windows/runner/resources/app_icon.ico"

echo "完成。"
