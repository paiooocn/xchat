#!/usr/bin/env bash
# Build release APK and copy versioned artifact into dist/.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJ="${PROJ:-$(cd "$SCRIPT_DIR/.." && pwd)}"

# Optional local toolchain overrides (CI provides these via env / setup actions).
if [ -n "${FLUTTER_BIN:-}" ]; then
  export PATH="$FLUTTER_BIN:$PATH"
fi
if [ -n "${ANDROID_SDK_ROOT:-}" ]; then
  export ANDROID_HOME="${ANDROID_HOME:-$ANDROID_SDK_ROOT}"
fi
if [ -n "${JAVA_HOME:-}" ]; then
  export PATH="$JAVA_HOME/bin:$PATH"
fi

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
