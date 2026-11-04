#!/usr/bin/env bash
# 发布构建产物到 GitCode Release：
#   1) 确保 tag 对应的 Release 存在（GET releases/tags/:tag，不存在则 POST 创建，带重试以容忍并行任务竞态）
#   2) 逐个文件上传：**每轮先刷新 Release 真实状态**（已有同名附件即跳过，修掉陈旧快照），
#      再重新获取 upload_url（预签名地址短时效，不能复用），最后 PUT（带 OBS 回调头）
#   3) 上传后**核验**附件是否真的出现在 Release 里（curl 退出码 0 不等于落地）
#   4) 单文件失败按退避重试（最多 UPLOAD_RETRIES 轮），最终失败**不中断**其余文件，
#      脚本结尾汇总；有失败则退出码 1 —— 重跑幂等（已存在的附件会被跳过）
#
# 用法: bash dist/gitcode_release.sh <artifact...>
#
# 环境变量:
#   GITCODE_TOKEN            必填  GitCode 私人令牌（access_token，需有仓库 Release 读写权限）
#   GITCODE_OWNER            必填  仓库所属空间地址（企业/组织/个人的 path）
#   GITCODE_REPO             必填  仓库路径
#   TAG_NAME                 必填  tag 名称，如 v0.1.9
#   RELEASE_NAME             选填  Release 名称（默认同 TAG_NAME）
#   RELEASE_BODY             选填  Release 描述
#   RELEASE_STATUS           选填  latest | pre（默认 latest）
#   GITCODE_API              选填  API 基址（默认 https://api.gitcode.com/api/v5）
#   UPLOAD_RETRIES           选填  单文件上传尝试轮数（默认 4）
#   UPLOAD_TIMEOUT           选填  单次上传 curl --max-time 秒数（默认 1800）
#   UPLOAD_CONNECT_TIMEOUT   选填  curl --connect-timeout 秒数（默认 15）
set -euo pipefail

API="${GITCODE_API:-https://api.gitcode.com/api/v5}"
TOKEN="${GITCODE_TOKEN:?GITCODE_TOKEN is required}"
OWNER="${GITCODE_OWNER:?GITCODE_OWNER is required}"
REPO="${GITCODE_REPO:?GITCODE_REPO is required}"
TAG="${TAG_NAME:?TAG_NAME is required}"
NAME="${RELEASE_NAME:-$TAG}"
BODY="${RELEASE_BODY:-}"
STATUS="${RELEASE_STATUS:-latest}"

MAX_ATTEMPTS="${UPLOAD_RETRIES:-4}"
UPLOAD_TIMEOUT="${UPLOAD_TIMEOUT:-1800}"
CONNECT_TIMEOUT="${UPLOAD_CONNECT_TIMEOUT:-15}"
case "$MAX_ATTEMPTS" in
  ''|*[!0-9]*) MAX_ATTEMPTS=4 ;;
esac
[ "$MAX_ATTEMPTS" -ge 1 ] || MAX_ATTEMPTS=1

command -v jq >/dev/null 2>&1 || { echo "!! jq is required" >&2; exit 1; }
command -v curl >/dev/null 2>&1 || { echo "!! curl is required" >&2; exit 1; }
[ $# -ge 1 ] || { echo "usage: $0 <artifact...>" >&2; exit 2; }

say()  { printf '==> %s\n' "$*"; }
warn() { printf '!! %s\n' "$*" >&2; }

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

RELEASE_JSON=""
LAST_CODE=""
LAST_ERR=""

# --- 0. 读取 Release 当前状态（每次上传/核验前都调用） ----------------------
refresh_release() {
  local code
  code=$(curl -sS -o "$TMP/release.json" -w '%{http_code}' \
    --connect-timeout "$CONNECT_TIMEOUT" --max-time 60 -G \
    "$API/repos/$OWNER/$REPO/releases/tags/$TAG" \
    --data-urlencode "access_token=$TOKEN" || true)
  if [ "$code" = "200" ]; then
    RELEASE_JSON="$(cat "$TMP/release.json")"
    return 0
  fi
  warn "刷新 release 状态失败（HTTP ${code:-000}）"
  return 1
}

# --- 1. 确保 Release 存在 ---------------------------------------------------
ensure_release() {
  local code attempt
  for attempt in 1 2 3 4; do
    code=$(curl -sS -o "$TMP/release.json" -w '%{http_code}' -G \
      --connect-timeout "$CONNECT_TIMEOUT" --max-time 60 \
      "$API/repos/$OWNER/$REPO/releases/tags/$TAG" \
      --data-urlencode "access_token=$TOKEN" || true)
    if [ "$code" = "200" ]; then
      RELEASE_JSON="$(cat "$TMP/release.json")"
      say "release 已存在: $TAG"
      return 0
    fi

    say "release 不存在（HTTP ${code:-000}），创建中: $TAG  ($NAME / $STATUS)"
    code=$(curl -sS -o "$TMP/release.json" -w '%{http_code}' -X POST \
      --connect-timeout "$CONNECT_TIMEOUT" --max-time 60 \
      "$API/repos/$OWNER/$REPO/releases?access_token=$TOKEN" \
      -H "Content-Type: application/json" \
      -d "$(jq -n --arg tag "$TAG" --arg name "$NAME" --arg body "$BODY" --arg st "$STATUS" \
           '{tag_name:$tag, name:$name, body:$body, release_status:$st}')" || true)
    if [ "$code" = "200" ] || [ "$code" = "201" ]; then
      RELEASE_JSON="$(cat "$TMP/release.json")"
      say "release 创建成功: $TAG"
      return 0
    fi

    warn "创建未成功（HTTP ${code:-000}: $(head -c 300 "$TMP/release.json")），${attempt}s 后重试..."
    sleep "$attempt"
  done

  warn "无法创建/获取 release: $TAG"
  exit 1
}

# --- 2. 附件是否已在 Release 里（按名字） -----------------------------------
asset_exists() {
  local name="$1"
  [ -n "$RELEASE_JSON" ] || return 1
  jq -e --arg n "$name" \
    '((.assets // []) | map(.name) | index($n)) != null' \
    <<<"$RELEASE_JSON" >/dev/null 2>&1
}

# --- 3. 单次上传（取新签名地址 + PUT），成功返回 0，并记录 LAST_CODE/LAST_ERR
upload_once() {
  local file="$1" fname="$2"
  local resp url hname hval code
  local args=()
  LAST_CODE=""
  LAST_ERR=""

  resp=$(curl -sS --connect-timeout "$CONNECT_TIMEOUT" --max-time 60 -G \
    "$API/repos/$OWNER/$REPO/releases/$TAG/upload_url" \
    --data-urlencode "access_token=$TOKEN" \
    --data-urlencode "file_name=$fname" || true)
  url=$(jq -r '.url // empty' <<<"$resp" 2>/dev/null || true)
  if [ -z "$url" ]; then
    LAST_ERR="获取上传地址失败: $(head -c 300 <<<"$resp")"
    return 1
  fi

  args=(-T "$file" -o "$TMP/put.out")
  for hname in x-obs-meta-project-id x-obs-acl x-obs-callback Content-Type; do
    hval=$(jq -r --arg k "$hname" '(.headers[$k]) // ""' <<<"$resp" 2>/dev/null || true)
    if [ "$hname" = "Content-Type" ] && [ -z "$hval" ]; then
      hval="application/octet-stream"
    fi
    if [ -n "$hval" ]; then args+=(-H "$hname: $hval"); fi
  done

  code=$(curl -sS -w '%{http_code}' \
    --connect-timeout "$CONNECT_TIMEOUT" --max-time "$UPLOAD_TIMEOUT" \
    "${args[@]}" "$url" || true)
  LAST_CODE="${code:-000}"
  case "$LAST_CODE" in
    2??) return 0 ;;
    *)
      LAST_ERR="HTTP $LAST_CODE"
      if [ -s "$TMP/put.out" ]; then
        LAST_ERR="$LAST_ERR: $(head -c 300 "$TMP/put.out" | tr -d '\0')"
      fi
      return 1
      ;;
  esac
}

# 401（token 无效）/ 404（owner·repo·tag 打错）重试没有意义，直接放弃
is_retryable() {
  case "$1" in
    401|404) return 1 ;;
    *) return 0 ;;
  esac
}

# --- 4. 带重试的上传 --------------------------------------------------------
upload_with_retry() {
  local file="$1" fname attempt delay
  fname="$(basename "$file")"

  for ((attempt = 1; attempt <= MAX_ATTEMPTS; attempt++)); do
    # 每轮都刷新真实状态：既修掉陈旧快照，也能识别「上次其实已落地」
    refresh_release || true
    if asset_exists "$fname"; then
      say "附件已存在，跳过: $fname"
      return 0
    fi

    say "上传 $fname（$(du -h "$file" | cut -f1)）第 ${attempt}/${MAX_ATTEMPTS} 轮"
    if upload_once "$file" "$fname"; then
      # 2xx 只代表请求成功；再核验附件是否真的出现在 Release 里
      if refresh_release && asset_exists "$fname"; then
        say "上传完成: $fname"
        return 0
      fi
      warn "$fname 返回 2xx，但 Release 里暂时看不到该附件，准备重试"
    else
      warn "$fname 上传失败：${LAST_ERR:-未知错误}"
      if ! is_retryable "$LAST_CODE"; then
        warn "$fname 不可重试（HTTP $LAST_CODE），放弃"
        return 1
      fi
    fi

    if [ "$attempt" -lt "$MAX_ATTEMPTS" ]; then
      case "$attempt" in
        1) delay=2 ;;
        2) delay=5 ;;
        *) delay=10 ;;
      esac
      say "${delay}s 后重试: $fname"
      sleep "$delay"
    fi
  done

  warn "$fname 连续 ${MAX_ATTEMPTS} 轮未成功"
  return 1
}

ensure_release

FAILED=()
for f in "$@"; do
  if [ ! -f "$f" ]; then
    warn "文件不存在: $f"
    FAILED+=("$(basename "$f")")
    continue
  fi
  upload_with_retry "$f" || FAILED+=("$(basename "$f")")
done

if [ "${#FAILED[@]}" -gt 0 ]; then
  warn "发布未完成，失败 ${#FAILED[@]} 个: ${FAILED[*]}"
  warn "已上传的附件下次会被自动跳过，重跑本脚本或整条 workflow 即可补齐"
  exit 1
fi

say "GITCODE_RELEASE_DONE ($TAG)"
