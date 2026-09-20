#!/usr/bin/env bash
# Build release APK and copy versioned artifact into dist/.
set -euo pipefail

export PATH="/home/yimo/.toolchain/flutter/bin:/home/yimo/.toolchain/flutter/bin/cache/dart-sdk/bin:$PATH"
export ANDROID_SDK_ROOT="/home/yimo/.toolchain/android-sdk"
export ANDROID_HOME="/home/yimo/.toolchain/android-sdk"
export JAVA_HOME="/home/yimo/.toolchain/jdk17"
export PATH="$JAVA_HOME/bin:$PATH"

PROJ="/mnt/kd/dop/pcr/aicoding/ds-xchat"
cd "$PROJ"

VERSION="$(grep -m1 '^version:' pubspec.yaml | sed -E 's/^version:[[:space:]]*//' | cut -d'+' -f1)"
echo "==> app version: v$VERSION"

flutter build apk --release

APK="build/app/outputs/flutter-apk/app-release.apk"
DEST="dist/xchat-v${VERSION}.apk"
mkdir -p dist
cp "$APK" "$DEST"
echo "==> copied to $DEST"
ls -la "$DEST"
echo "==> BUILD_DONE"
