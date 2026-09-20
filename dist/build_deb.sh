#!/usr/bin/env bash
# Build the Linux release bundle and package it as dist/xchat-v{x.y.z}.deb.
set -euo pipefail

PROJ="/mnt/kd/dop/pcr/aicoding/ds-xchat"
FLUTTER_BIN="${FLUTTER_BIN:-/home/yimo/.toolchain/flutter/bin}"
export PATH="$FLUTTER_BIN:$PATH"

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
         "$PKG/usr/share/applications" \
         "$PKG/usr/share/icons/hicolor/192x192/apps"

cp -r "$BUNDLE/." "$PKG/usr/lib/xchat/"
ln -sf /usr/lib/xchat/xchat "$PKG/usr/bin/xchat"
cp "android/app/src/main/res/mipmap-xxxhdpi/ic_launcher.png" \
   "$PKG/usr/share/icons/hicolor/192x192/apps/xchat.png"

cat > "$PKG/usr/share/applications/xchat.desktop" <<'EOF'
[Desktop Entry]
Type=Application
Name=XChat
Comment=Cross-platform LLM agent GUI (ReAct + XML sessions)
Exec=xchat
Icon=xchat
Terminal=false
Categories=Utility;Development;
EOF

cat > "$PKG/DEBIAN/control" <<EOF
Package: xchat
Version: ${VERSION}
Section: utils
Priority: optional
Architecture: ${ARCH}
Maintainer: xchat
Depends: libgtk-3-0, libblkid1, liblzma5, libstdc++6
Description: XChat - cross-platform LLM agent GUI
 ReAct + XML session based desktop client for LLM agents.
EOF

mkdir -p dist
DEST="dist/xchat-v${VERSION}.deb"
dpkg-deb --build --root-owner-group "$PKG" "$DEST"
echo "==> built $DEST"
ls -la "$DEST"
echo "==> BUILD_DONE"
