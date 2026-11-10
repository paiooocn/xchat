#!/usr/bin/env bash
# Bump the app version in one shot — keeps pubspec.yaml and
# lib/core/app_version.dart in sync (test/app_version_test.dart guards the pair).
#
#   ./dist/bump_version.sh              # 修订号 +1（0.7.7 -> 0.7.8）
#   ./dist/bump_version.sh -c           # 同上，且跳过确认
#   ./dist/bump_version.sh -z 3         # 修订号 +3
#   ./dist/bump_version.sh -y 1         # 次版本号 +1，修订号归 0（0.7.7 -> 0.8.0）
#   ./dist/bump_version.sh -y 1 -f      # 次版本号 +1，修订号不动（0.7.7 -> 0.8.7）
#   ./dist/bump_version.sh -x           # 主版本号 +1，次/修订归 0（0.7.7 -> 1.0.0）
#   ./dist/bump_version.sh -x -f        # 主版本号 +1，其余不动（0.7.7 -> 1.7.7）
#   ./dist/bump_version.sh -b 2         # 构建号 +2（版号不变时才有意义）
#   ./dist/bump_version.sh -y 1 -b 1    # 可组合
#   ./dist/bump_version.sh -d -b 1      # -d 直接赋值：构建号设为 1（0.7.7+5 -> 0.7.7+1）
#   ./dist/bump_version.sh -d -z 5      # 修订号设为 5（0.7.7 -> 0.7.5）
#   ./dist/bump_version.sh -d -x 2      # 主版本设为 2，次/修订归 0（0.7.7 -> 2.0.0）
#   ./dist/bump_version.sh -d -x 2 -f   # 主版本设为 2，其余不动（0.7.7 -> 2.7.7）
#   ./dist/bump_version.sh -m 1.2.3     # 直接设为 1.2.3（构建号重置为 1）
#   ./dist/bump_version.sh -m 1.2.3 -b 1  # 版号变了 → 构建号仍是 1（-b 被忽略）
#   ./dist/bump_version.sh -s           # 只显示当前版本号
#
# 归零规则（低位随高位归 0）：-y 把修订号归 0；-x 把次版本号与修订号都归 0。
# 同一条命令里被显式给出的段不归零（-y 1 -z 2 的修订号仍是 +2）；
# -f/--frozen 让本次升版完全不归零。
# 构建号规则：x.y.z 任一段发生变化（含 -m）→ 构建号重置为 1（`-b` 被忽略并提示）；
# 版号不变、只给了 -b → 构建号 += N。所以 +N 永远只属于同一个版号。
# -d/--direct：把 -z/-y/-x/-b 的参数从「增量」改为「绝对值」（-b 成为显式指定，
# 优先于上面的重置规则）；未给出的段保持原值，归零规则照旧（-f 关掉）。
#
# 选项：
#   -c, --yes       自动确认（不 -c 时先打印计划，等 y 确认；非交互环境必须 -c）
#   -z, --patch N   修订号（第三段）+N；-d 时为「设为 N」
#   -y, --minor N   次版本号（第二段）+N；-d 时为「设为 N」
#   -x, --major [N] 主版本号（第一段）+N（默认 1）；-d 时为「设为 N」
#   -b, --build N   构建号（`+` 之后）+N（版号同时变则忽略，重置为 1）；
#                   -d 时为「设为 N」（优先于重置）
#   -d, --direct    参数改为绝对值（直接赋值），而不是增量
#   -f, --frozen    升次/主版本时不把低位归 0
#   -m, --manual V  直接把版号设为 V（x.y.z，可带前导 v）；不能与 -z/-y/-x 同用
#   -s, --show      显示当前版本号后退出
#   -h, --help      显示本帮助
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
    awk 'NR > 1 { if ($0 ~ /^#/) { sub(/^# ?/, ""); print; next } exit }' "${BASH_SOURCE[0]}"
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
ANY_BUMP=0   # -z/-y/-x/-b 任一给过
VER_BUMP=0   # -z/-y/-x 任一给过（-b 不算）
FROZEN=0
DIRECT=0
MANUAL=""
SET_MAJOR=0 # -x 显式给过
SET_MINOR=0 # -y 显式给过（归零时跳过这一段）
SET_PATCH=0 # -z 显式给过

need_n() {
    # need_n <flag> <value?>：必须给出且为 >0 的整数
    [ -n "${2-}" ] || die "选项 $1 需要一个非负整数参数"
    [[ "$2" =~ ^[0-9]+$ ]] || die "选项 $1 的参数必须是整数：'$2'"
    [ "$2" -gt 0 ] || die "选项 $1 的参数必须大于 0"
    printf '%s' "$2"
}

need_num() {
    # need_num <flag> <value?>：>0 的整数；-d 下允许 0（表示「设为 0」）
    [ -n "${2-}" ] || die "选项 $1 需要一个非负整数参数"
    [[ "$2" =~ ^[0-9]+$ ]] || die "选项 $1 的参数必须是整数：'$2'"
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
            STEP_PATCH="$(need_num "$1" "${2-}")"
            SET_PATCH=1
            ANY_BUMP=1
            VER_BUMP=1
            shift
            ;;
        -y | --minor)
            STEP_MINOR="$(need_num "$1" "${2-}")"
            SET_MINOR=1
            ANY_BUMP=1
            VER_BUMP=1
            shift
            ;;
        -x | --major)
            if [[ "${2-}" =~ ^[0-9]+$ ]]; then
                STEP_MAJOR="$2"
                shift
            else
                STEP_MAJOR=1
            fi
            SET_MAJOR=1
            ANY_BUMP=1
            VER_BUMP=1
            ;;
        -b | --build)
            STEP_BUILD="$(need_n "$1" "${2-}")"
            ANY_BUMP=1
            shift
            ;;
        -d | --direct) DIRECT=1 ;;
        -f | --frozen) FROZEN=1 ;;
        -m | --manual)
            [ -n "${2-}" ] || die "选项 $1 需要一个 x.y.z 形式的版号"
            mv_ver="$(printf '%s' "$2" | sed -E 's/^[vV]//')"
            [[ "$mv_ver" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || die "选项 $1 的参数必须是 x.y.z：'$2'"
            MANUAL="$mv_ver"
            shift
            ;;
        *) die "未知参数 '$1'（--help 看用法）" ;;
    esac
    shift
done

# -d 只是「改解释方式」，本身不指明改哪一段
if [ "$DIRECT" -eq 1 ] && [ "$ANY_BUMP" -eq 0 ]; then
    die "-d/--direct 需要配合 -z/-y/-x/-b 使用（说明要把哪一段设成多少）"
fi

# 0 只在 -d（直接赋值）下有意义
if [ "$DIRECT" -eq 0 ]; then
    if [ "$SET_PATCH" -eq 1 ] && [ "$STEP_PATCH" -eq 0 ]; then
        die "-z 的参数必须大于 0（0 只在 -d 下表示「设为 0」）"
    fi
    if [ "$SET_MINOR" -eq 1 ] && [ "$STEP_MINOR" -eq 0 ]; then
        die "-y 的参数必须大于 0（0 只在 -d 下表示「设为 0」）"
    fi
    if [ "$SET_MAJOR" -eq 1 ] && [ "$STEP_MAJOR" -eq 0 ]; then
        die "-x 的参数必须大于 0（0 只在 -d 下表示「设为 0」）"
    fi
fi

# 无任何升版参数 = 修订号 +1（-m 自带完整版号，不参与默认升版）
if [ "$ANY_BUMP" -eq 0 ] && [ -z "$MANUAL" ]; then
    STEP_PATCH=1
fi

if [ -n "$MANUAL" ]; then
    [ "$VER_BUMP" -eq 0 ] || die "-m/--manual 不能与 -z/-y/-x 同用（-b 可以）"
fi

# -------------------------------------------------------------------- 计算新号

if [ -n "$MANUAL" ]; then
    IFS='.' read -r NEW_MAJOR NEW_MINOR NEW_PATCH <<<"$MANUAL"
elif [ "$DIRECT" -eq 1 ]; then
    # -d：给出的段是绝对值，未给出的段保持原值
    NEW_MAJOR=$MAJOR
    NEW_MINOR=$MINOR
    NEW_PATCH=$PATCH
    [ "$SET_MAJOR" -eq 1 ] && NEW_MAJOR=$STEP_MAJOR
    [ "$SET_MINOR" -eq 1 ] && NEW_MINOR=$STEP_MINOR
    [ "$SET_PATCH" -eq 1 ] && NEW_PATCH=$STEP_PATCH
else
    NEW_MAJOR=$((MAJOR + STEP_MAJOR))
    NEW_MINOR=$((MINOR + STEP_MINOR))
    NEW_PATCH=$((PATCH + STEP_PATCH))

fi

# 低位随高位归 0：-x 归次/修订，-y 归修订；显式给出的段与 -f 不受影响。
# -d 下同样成立（「设主版本」= 一次主版本变更），只是显式段的判定用 SET_*。
ZERO_MINOR=0 # -x 抬起主版本 → 次版本归 0
ZERO_PATCH=0 # -x/-y 抬起高位 → 修订号归 0
if [ -n "$MANUAL" ]; then
    :
elif [ "$DIRECT" -eq 1 ]; then
    if [ "$SET_MAJOR" -eq 1 ] && [ "$STEP_MAJOR" -gt "$MAJOR" ]; then
        ZERO_MINOR=1
        ZERO_PATCH=1
    elif [ "$SET_MINOR" -eq 1 ] && [ "$STEP_MINOR" -gt "$MINOR" ]; then
        ZERO_PATCH=1
    fi
else
    if [ "$STEP_MAJOR" -gt 0 ]; then
        ZERO_MINOR=1
        ZERO_PATCH=1
    elif [ "$STEP_MINOR" -gt 0 ]; then
        ZERO_PATCH=1
    fi
fi
if [ "$FROZEN" -eq 0 ]; then
    if [ "$ZERO_PATCH" -eq 1 ] && [ "$SET_PATCH" -eq 0 ]; then
        NEW_PATCH=0
    fi
    if [ "$ZERO_MINOR" -eq 1 ] && [ "$SET_MINOR" -eq 0 ]; then
        NEW_MINOR=0
    fi
fi

NEW_VER="$NEW_MAJOR.$NEW_MINOR.$NEW_PATCH"

# 构建号跟着版号走：x.y.z 任一段变了就重置为 1，只有版号不变时才累加 -b。
# -d 下 -b 是「设为 N」，优先级高于重置（用户明确指定了要哪个构建号）。
BUILD_RESET=0
if [ "$DIRECT" -eq 1 ] && [ "$STEP_BUILD" -gt 0 ]; then
    NEW_BUILD=$STEP_BUILD
elif [ "$NEW_VER" != "$VER" ]; then
    NEW_BUILD=1
    BUILD_RESET=1
else
    NEW_BUILD=$((BUILD + STEP_BUILD))
fi
NEW_FULL="$NEW_VER+$NEW_BUILD"

printf '当前版本: %s\n' "$CURRENT"
printf '新版本:   %s\n' "$NEW_FULL"
if [ -n "$MANUAL" ]; then
    printf '（-m 直接指定版号%s）\n' "$([ "$BUILD_RESET" -eq 1 ] && printf '，构建号重置为 1' || printf '（版号未变），构建号不动')"
else
    if [ "$DIRECT" -eq 1 ]; then
        printf '（-d 直接赋值：给出的段替换原值，其余保持不变）\n'
    fi
    if [ "$FROZEN" -eq 0 ] && [ "$ZERO_PATCH" -eq 1 -o "$ZERO_MINOR" -eq 1 ]; then
        printf '（低位已归 0，加 -f 可保持递进）\n'
    fi
fi
if [ "$BUILD_RESET" -eq 1 ] && [ "$STEP_BUILD" -gt 0 ]; then
    printf '（版号已变，构建号重置为 1：忽略 -b %s）\n' "$STEP_BUILD"
fi

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
