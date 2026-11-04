#!/usr/bin/env bash
# Build release APK and copy versioned artifact into dist/.
#
# 除了正式版（XChat），还会**多打一个只改应用名**的版本（默认 SixChat）：
#   flutter build apk --release --dart-define=APP_BRAND_NAME=SixChat
# 改名版的 applicationId / 版本号 / 数据目录与正式版完全一致，只有显示名不同。
#
# 用法: dist/build_apk.sh [-p]
#   -p, --primary  只打包正式版（产物仅 dist/xchat-v*.apk），不打包改名版
#
# 环境变量:
#   BRAND_VARIANT_NAME  改名版的显示名（默认 SixChat）
#   BUILD_BRAND_VARIANT  设为 0 则不打包改名版（默认打包）
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJ="${PROJ:-$(cd "$SCRIPT_DIR/.." && pwd)}"

PRIMARY_ONLY=0
for arg in "$@"; do
  case "$arg" in
    -p|--primary) PRIMARY_ONLY=1 ;;
    -h|--help) sed -n '2,13p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "!! 未知参数: $arg（可用: -p）" >&2; exit 2 ;;
  esac
done

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

# 是否打包改名版：默认打包；-p 或 BUILD_BRAND_VARIANT=0 时只打正式版。
BUILD_VARIANT=1
[ "${BUILD_BRAND_VARIANT:-1}" = "0" ] && BUILD_VARIANT=0
[ "$PRIMARY_ONLY" = "1" ] && BUILD_VARIANT=0

# 改名版：只改显示名，默认 SixChat。
VARIANT_NAME="${BRAND_VARIANT_NAME:-SixChat}"
VARIANT_SLUG="$(printf '%s' "$VARIANT_NAME" | tr '[:upper:]' '[:lower:]' | tr -cd 'a-z0-9-')"
[ -n "$VARIANT_SLUG" ] || VARIANT_SLUG="variant"

build_apk() {
  local dest="$1"; shift
  flutter build apk --release "$@"
  APK="build/app/outputs/flutter-apk/app-release.apk"
  mkdir -p dist
  cp "$APK" "$dest"
  echo "==> copied to $dest"
  ls -la "$dest"
}

build_apk "dist/xchat-v${VERSION}.apk"

if [ "$BUILD_VARIANT" = "1" ]; then
  echo "==> building brand variant: $VARIANT_NAME"
  build_apk "dist/${VARIANT_SLUG}-v${VERSION}.apk" "--dart-define=APP_BRAND_NAME=${VARIANT_NAME}"
fi

# 仅保留当前与上一次打包的 apk：按修改时间保留最新 2 个，删除更旧的。
prune_apks() {
  local pattern="$1"
  ls -t $pattern 2>/dev/null | tail -n +3 | while IFS= read -r old; do
    echo "==> pruning old artifact: $old"
    rm -f "$old"
  done || true
}
prune_apks "dist/xchat-v*.apk"
if [ "$BUILD_VARIANT" = "1" ]; then
  prune_apks "dist/${VARIANT_SLUG}-v*.apk"
fi

echo "==> BUILD_DONE"
