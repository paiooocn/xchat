#!/usr/bin/env bash
# Build the Linux release bundle and package it as dist/{slug}-v{x.y.z}.deb.
#
# 除了正式版（XChat），还会**多打一个只改应用名**的版本（默认 SixChat）：
#   APP_BRAND_NAME=SixChat flutter build linux --release --dart-define=APP_BRAND_NAME=SixChat
# 改名版的包名 / 安装路径 / applicationId 与正式版完全一致，只有显示名不同。
#
# 环境变量:
#   BRAND_VARIANT_NAME  改名版的显示名（默认 SixChat）
#   BUILD_BRAND_VARIANT  设为 0 则不打包改名版（默认打包）
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJ="${PROJ:-$(cd "$SCRIPT_DIR/.." && pwd)}"

if [ -n "${FLUTTER_BIN:-}" ]; then
  export PATH="$FLUTTER_BIN:$PATH"
fi

cd "$PROJ"

VERSION="$(grep -m1 '^version:' pubspec.yaml | sed -E 's/^version:[[:space:]]*//' | cut -d'+' -f1)"
ARCH="$(dpkg --print-architecture 2>/dev/null || echo amd64)"
echo "==> app version: v$VERSION  arch: $ARCH"

# 改名版：只改显示名，默认 SixChat。
VARIANT_NAME="${BRAND_VARIANT_NAME:-SixChat}"
VARIANT_SLUG="$(printf '%s' "$VARIANT_NAME" | tr '[:upper:]' '[:lower:]' | tr -cd 'a-z0-9-')"
[ -n "$VARIANT_SLUG" ] || VARIANT_SLUG="variant"

# 打包一个 deb：$1 = 显示名（XChat / SixChat），$2 = 产物前缀（xchat / sixchat）
build_deb() {
  local brand="$1" slug="$2"
  local pkg="build/deb/pkg"
  local bundle="build/linux/x64/release/bundle"

  echo "==> building linux bundle: $brand"
  # 桌面端原生窗口标题由 CMake 从环境变量 APP_BRAND_NAME 读，Dart 侧用
  # --dart-define，两者必须同名。删掉 build/linux 让 CMake 重新 configure
  #（否则 CMake 缓存里还是上一次的显示名）。
  rm -rf build/linux
  APP_BRAND_NAME="$brand" flutter build linux --release --dart-define="APP_BRAND_NAME=${brand}"

  [ -d "$bundle" ] || bundle="$(dirname "$(find build/linux -type f -name xchat -path '*release/bundle*' | head -1)")"
  [ -d "$bundle" ] || { echo "!! linux bundle not found"; exit 1; }
  echo "==> bundle: $bundle"

  rm -rf "$pkg"
  mkdir -p "$pkg/DEBIAN" \
           "$pkg/usr/lib/xchat" \
           "$pkg/usr/bin" \
           "$pkg/usr/share/applications"

  cp -r "$bundle/." "$pkg/usr/lib/xchat/"
  ln -sf /usr/lib/xchat/xchat "$pkg/usr/bin/xchat"

  # ---- 内置 Python（tool/fetch_python.sh 下载后拷入 /usr/lib/xchat/runtime/python）----
  # 版本单一来源：tool/python_version.txt（如 3.12.13）
  PY_VERSION="$(tr -d '[:space:]' < "$PROJ/tool/python_version.txt" 2>/dev/null || echo 3.12.13)"
  PY_SRC="$(find "$PROJ/third_party/python" -maxdepth 2 -type d -name "cpython-${PY_VERSION}-*" 2>/dev/null | head -1)"
  if [ -n "$PY_SRC" ]; then
    mkdir -p "$pkg/usr/lib/xchat/runtime"
    cp -a "$PY_SRC" "$pkg/usr/lib/xchat/runtime/python"
    echo "==> bundled python: $PY_SRC"
  else
    echo "!! 未找到 third_party/python/cpython-${PY_VERSION}-*，本次不带内置 Python"
  fi
  # 应用自己的图标：放在应用目录内，.desktop 用绝对路径引用，
  # 不往系统图标主题目录里塞文件（也就不需要动任何 index.theme）。
  mkdir -p "$pkg/usr/lib/xchat/data/icons"
  cp "assets/icons/app_icon.png" "$pkg/usr/lib/xchat/data/icons/com.yimo.xchat.png"

  # 条目 id 与应用的 APPLICATION_ID / WM_CLASS 一致（com.yimo.xchat），
  # 否则 GNOME 匹配不到运行中的窗口，开始菜单与 Dock 会显示通用齿轮图标。
  # Name 用显示名（改名版为 SixChat），包名与安装路径保持不变。
  cat > "$pkg/usr/share/applications/com.yimo.xchat.desktop" <<EOF
[Desktop Entry]
Type=Application
Name=${brand}
Comment=LLM Agent 图形客户端（会话 / 项目 / 模板）
Exec=/usr/bin/xchat
Icon=/usr/lib/xchat/data/icons/com.yimo.xchat.png
Terminal=false
Categories=Development;
StartupNotify=true
StartupWMClass=com.yimo.xchat
EOF

  cat > "$pkg/DEBIAN/control" <<EOF
Package: xchat
Version: ${VERSION}
Section: utils
Priority: optional
Architecture: ${ARCH}
Maintainer: xchat
Depends: libgtk-3-0, libblkid1, liblzma5, libstdc++6, libwebkit2gtk-4.1-0
Description: ${brand} - cross-platform LLM agent GUI
 ReAct + XML session based desktop client for LLM agents.
EOF

  mkdir -p dist
  DEST="dist/${slug}-v${VERSION}.deb"
  dpkg-deb --build --root-owner-group "$pkg" "$DEST"
  echo "==> built $DEST"
  ls -la "$DEST"
}

build_deb "XChat" "xchat"

if [ "${BUILD_BRAND_VARIANT:-1}" != "0" ]; then
  build_deb "$VARIANT_NAME" "$VARIANT_SLUG"
fi

# 仅保留当前与上一次打包的 deb：按修改时间保留最新 2 个，删除更旧的。
prune_debs() {
  local pattern="$1"
  ls -t $pattern 2>/dev/null | tail -n +3 | while IFS= read -r old; do
    echo "==> pruning old artifact: $old"
    rm -f "$old"
  done || true
}
prune_debs "dist/xchat-v*.deb"
if [ "${BUILD_BRAND_VARIANT:-1}" != "0" ]; then
  prune_debs "dist/${VARIANT_SLUG}-v*.deb"
fi

echo "==> BUILD_DONE"
