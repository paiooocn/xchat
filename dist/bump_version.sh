#!/usr/bin/env bash
# Bump the app version in one shot — keeps pubspec.yaml and
# lib/core/app_version.dart in sync (test/app_version_test.dart guards the pair).
#
#   ./dist/bump_version.sh              # 修订号 +1（0.7.7 -> 0.7.8）
#   ./dist/bump_version.sh -c           # 同上，且跳过确认
#   ./dist/bump_version.sh -z 3         # 修订号 +3
#   ./dist/bump_version.sh -y 1         # 次版本号 +1
#   ./dist/bump_version.sh -x           # 主版本号 +1
#   ./dist/bump_version.sh -b 2         # 构建号 +2（version: X.Y.Z+2）
#   ./dist/bump_version.sh -y 1 -b 1    # 可组合
#   ./dist/bump_version.sh -s           # 只显示当前版本号
#
# 选项：
#   -c, --yes      自动确认（不 -c 时先打印计划，等 y 确认；非交互环境必须 -c）
#   -z, --patch N  修订号（第三段）+N
#   -y, --minor N  次版本号（第二段）+N
#   -x, --major    主版本号（第一段）+1
#   -b, --build N  构建号（`+` 之后）+N
#   -s, --show     显示当前版本号后退出
#   -h, --help     显示本帮助
#
# 不带任何升版参数时等价于 `-z 1`。
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PUBSPEC="$ROOT/pubspec.yaml"
APPVER="$ROOT/lib/core/app_version.dart"

die() {
    printf 'error: %s\n' "$*" >&2
    exit 2
}

usage() {
    sed -n '2,23p' "${BASH_SOURCE[0]}" | sed -E 's/^# ?//'
}

[ -f "$PUBSPEC" ] || die "找不到 $PUBSPEC"
[ -f "$APPVER" ] || die "找不到 $APPVER"

# ---------------------------------------------------------------- 读取当前版号

current_line() {
    grep -m1 -E '^version:' "$PUBSPEC" | sed -E 's/^version:[[:space:]]*//' |
        tr -d '[:space:]'
}

CURRENT="$(current_line)"
[ -n "$CURRENT" ] || die "pubspec.yaml 里没有 version: 字段"

VER="${CURRENT%%+*}"
BUILD="1"
[ "$VER" != "$CURRENT" ] && BUILD="${CURRENT##*+}"
IFS='.' read -r MAJOR MINOR PATCH <<<"$VER"
for part in "$MAJOR" "$MINOR" "$PATCH"; do
    [[ "$part" =~ ^[0-9]+$ ]] || die "无法解析版本号 '$VER'（需要 X.Y.Z）"
done
[[ "$BUILD" =~ ^[0-9]+$ ]] || die "无法解析构建号 '$BUILD'"

# app_version.dart 是否掉队（发版前必须一致，否则应用内显示会滞后）
DART_VER="$(sed -nE "s/^const String kAppVersion = '([^']*)'.*/\1/p" "$APPVER")"
DART_BUILD="$(sed -nE 's/^const int kAppBuildNumber = ([0-9]+).*/\1/p' "$APPVER")"

show() {
    printf '%s\n' "$CURRENT"
    if [ "$DART_VER" != "$VER" ] || [ "$DART_BUILD" != "$BUILD" ]; then
        printf 'warning: lib/core/app_version.dart 是 %s+%s（与 pubspec 不一致，跑一次本脚本即可同步）\n' \
            "${DART_VER:-?}" "${DART_BUILD:-?}" >&2
    fi
}

# -------------------------------------------------------------------- 参数解析

CONFIRM=0
STEP_PATCH=0
STEP_MINOR=0
STEP_MAJOR=0
STEP_BUILD=0
ANY_BUMP=0

need_n() {
    # need_n <flag> <value?>
    [ -n "${2-}" ] || die "选项 $1 需要一个非负整数参数"
    [[ "$2" =~ ^[0-9]+$ ]] || die "选项 $1 的参数必须是整数：'$2'"
    [ "$2" -gt 0 ] || die "选项 $1 的参数必须大于 0"
    printf '%s' "$2"
}

while [ $# -gt 0 ]; do
    case "$1" in
        -c | --yes) CONFIRM=1 ;;
        -s | --show)
            show
            exit 0
            ;;
        -h | --help)
            usage
            exit 0
            ;;
        -z | --patch)
            STEP_PATCH="$(need_n "$1" "${2-}")"
            ANY_BUMP=1
            shift
            ;;
        -y | --minor)
            STEP_MINOR="$(need_n "$1" "${2-}")"
            ANY_BUMP=1
            shift
            ;;
        -x | --major)
            STEP_MAJOR=1
            ANY_BUMP=1
            ;;
        -b | --build)
            STEP_BUILD="$(need_n "$1" "${2-}")"
            ANY_BUMP=1
            shift
            ;;
        *) die "未知参数 '$1'（--help 看用法）" ;;
    esac
    shift
done

# 无任何升版参数 = 修订号 +1
if [ "$ANY_BUMP" -eq 0 ]; then
    STEP_PATCH=1
fi

# -------------------------------------------------------------------- 计算新号

NEW_MAJOR=$((MAJOR + STEP_MAJOR))
NEW_MINOR=$((MINOR + STEP_MINOR))
NEW_PATCH=$((PATCH + STEP_PATCH))
NEW_BUILD=$((BUILD + STEP_BUILD))
NEW_VER="$NEW_MAJOR.$NEW_MINOR.$NEW_PATCH"
NEW_FULL="$NEW_VER+$NEW_BUILD"

printf '当前版本: %s\n' "$CURRENT"
printf '新版本:   %s\n' "$NEW_FULL"

if [ "$NEW_FULL" = "$CURRENT" ]; then
    printf 'nothing to do（新旧版本相同）\n'
    exit 0
fi

# ---------------------------------------------------------------------- 确认

if [ "$CONFIRM" -ne 1 ]; then
    if [ ! -t 0 ]; then
        die "非交互环境请加 -c 自动确认"
    fi
    printf '确认升版? [y/N] '
    read -r answer
    case "$answer" in
        y | Y | yes | YES) ;;
        *)
            printf '已取消\n'
            exit 1
            ;;
    esac
fi

# ---------------------------------------------------------------------- 写回

# pubspec.yaml：只替换那唯一一行 version
tmp="$(mktemp)"
awk -v v="$NEW_FULL" '
    !done && /^version:/ { print "version: " v; done = 1; next }
    { print }
' "$PUBSPEC" >"$tmp"
cat "$tmp" >"$PUBSPEC"
rm -f "$tmp"

# app_version.dart：两个常量同步
tmp="$(mktemp)"
sed -E \
    -e "s/^const String kAppVersion = '[^']*';/const String kAppVersion = '$NEW_VER';/" \
    -e "s/^const int kAppBuildNumber = [0-9]+;/const int kAppBuildNumber = $NEW_BUILD;/" \
    "$APPVER" >"$tmp"
cat "$tmp" >"$APPVER"
rm -f "$tmp"

# 复核（写坏了要立刻炸，而不是留到发版后）
[ "$(current_line)" = "$NEW_FULL" ] || die "写 pubspec.yaml 失败（当前是 $(current_line)）"
grep -q "kAppVersion = '$NEW_VER';" "$APPVER" || die "写 app_version.dart 的 kAppVersion 失败"
grep -q "kAppBuildNumber = $NEW_BUILD;" "$APPVER" || die "写 app_version.dart 的 kAppBuildNumber 失败"

printf '已写入:\n  %s\n  %s\n' "$PUBSPEC" "$APPVER"
printf '校验: %s\n' "$NEW_FULL"
printf '下一步: flutter test test/app_version_test.dart && dist/build_apk.sh -p\n'
