#!/usr/bin/env bash
# Build the Linux release bundle and package it as dist/xchat-v{x.y.z}.deb.
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

flutter build linux --release

BUNDLE="build/linux/x64/release/bundle"
[ -d "$BUNDLE" ] || BUNDLE="$(dirname "$(find build/linux -type f -name xchat -path '*release/bundle*' | head -1)")"
[ -d "$BUNDLE" ] || { echo "!! linux bundle not found"; exit 1; }
echo "==> bundle: $BUNDLE"

PKG="build/deb/pkg"
rm -rf "$PKG"
mkdir -p "$PKG/DEBIAN" \
         "$PKG/usr/lib/xchat" \
         "$PKG/usr/bin" \
         "$PKG/usr/share/applications"

cp -r "$BUNDLE/." "$PKG/usr/lib/xchat/"
ln -sf /usr/lib/xchat/xchat "$PKG/usr/bin/xchat"

# ---- 内置 Python（tool/fetch_python.sh 下载后拷入 /usr/lib/xchat/runtime/python）----
# 版本单一来源：tool/python_version.txt（如 3.12.13）
PY_VERSION="$(tr -d '[:space:]' < "$PROJ/tool/python_version.txt" 2>/dev/null || echo 3.12.13)"
PY_SRC="$(find "$PROJ/third_party/python" -maxdepth 2 -type d -name "cpython-${PY_VERSION}-*" 2>/dev/null | head -1)"
if [ -n "$PY_SRC" ]; then
  mkdir -p "$PKG/usr/lib/xchat/runtime"
  cp -a "$PY_SRC" "$PKG/usr/lib/xchat/runtime/python"
  echo "==> bundled python: $PY_SRC"
else
  echo "!! 未找到 third_party/python/cpython-${PY_VERSION}-*，本次不带内置 Python"
fi
# 应用自己的图标：放在应用目录内，.desktop 用绝对路径引用，
# 不往系统图标主题目录里塞文件（也就不需要动任何 index.theme）。
mkdir -p "$PKG/usr/lib/xchat/data/icons"
cp "assets/icons/app_icon.png" "$PKG/usr/lib/xchat/data/icons/com.yimo.xchat.png"

# 条目 id 与应用的 APPLICATION_ID / WM_CLASS 一致（com.yimo.xchat），
# 否则 GNOME 匹配不到运行中的窗口，开始菜单与 Dock 会显示通用齿轮图标。
cat > "$PKG/usr/share/applications/com.yimo.xchat.desktop" <<'EOF'
[Desktop Entry]
Type=Application
Name=XChat
Comment=LLM Agent 图形客户端（会话 / 项目 / 模板）
Exec=/usr/bin/xchat
Icon=/usr/lib/xchat/data/icons/com.yimo.xchat.png
Terminal=false
Categories=Development;
StartupNotify=true
StartupWMClass=com.yimo.xchat
EOF

cat > "$PKG/DEBIAN/control" <<EOF
Package: xchat
Version: ${VERSION}
Section: utils
Priority: optional
Architecture: ${ARCH}
Maintainer: xchat
Depends: libgtk-3-0, libblkid1, liblzma5, libstdc++6, libwebkit2gtk-4.1-0
Description: XChat - cross-platform LLM agent GUI
 ReAct + XML session based desktop client for LLM agents.
EOF

mkdir -p dist
DEST="dist/xchat-v${VERSION}.deb"
dpkg-deb --build --root-owner-group "$PKG" "$DEST"
echo "==> built $DEST"
ls -la "$DEST"

# 仅保留当前与上一次打包的 deb：按修改时间保留最新 2 个，删除更旧的。
ls -t dist/xchat-v*.deb 2>/dev/null | tail -n +3 | while IFS= read -r old; do
  echo "==> pruning old artifact: $old"
  rm -f "$old"
done || true

echo "==> BUILD_DONE"
