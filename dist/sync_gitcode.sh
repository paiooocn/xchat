#!/usr/bin/env bash
# 单向同步 GitHub 仓库 -> GitCode（所有分支 + 所有 tag；GitHub 为唯一事实源）。
#
# 用法: bash dist/sync_gitcode.sh   （需在含完整 git 历史的检出中运行，如 actions/checkout fetch-depth: 0）
#
# 环境变量:
#   GITCODE_ACCESS_KEY / GITCODE_TOKEN  私人令牌（HTTPS 推送鉴权，与 GITCODE_SSH_KEY 二选一）
#   GITCODE_SSH_KEY                     可选，SSH 私钥；设置后走 SSH 推送
#   GITCODE_PUSH_USER                   HTTPS 推送用户名（默认 yimopub；若 401 请改为令牌所属账号名）
#   GITCODE_OWNER                       默认 yimopub
#   GITCODE_REPO                        默认 xchat
set -euo pipefail

OWNER="${GITCODE_OWNER:-yimopub}"
REPO="${GITCODE_REPO:-xchat}"
TOKEN="${GITCODE_TOKEN:-${GITCODE_ACCESS_KEY:-}}"
PUSH_USER="${GITCODE_PUSH_USER:-yimopub}"

say() { printf '==> %s\n' "$*"; }

if [ -n "${GITCODE_SSH_KEY:-}" ]; then
  say "鉴权方式: SSH 密钥"
  mkdir -p ~/.ssh && chmod 700 ~/.ssh
  printf '%s\n' "$GITCODE_SSH_KEY" > ~/.ssh/gitcode_key
  chmod 600 ~/.ssh/gitcode_key
  export GIT_SSH_COMMAND="ssh -i $HOME/.ssh/gitcode_key -o StrictHostKeyChecking=accept-new"
  DEST="git@gitcode.com:$OWNER/$REPO.git"
  AUTH=()
else
  [ -n "$TOKEN" ] || { echo "!! 缺少 GITCODE_ACCESS_KEY（或 GITCODE_SSH_KEY）" >&2; exit 1; }
  say "鉴权方式: HTTPS + 私人令牌（user=$PUSH_USER）"
  DEST="https://gitcode.com/$OWNER/$REPO.git"
  export X_USER="$PUSH_USER" X_TOKEN="$TOKEN"
  AUTH=(-c 'credential.helper=!f() { echo "username=$X_USER"; echo "password=$X_TOKEN"; }; f')
fi

say "拉取 GitHub 全部分支与标签"
# 分支落到临时命名空间 refs/sync/*，避免 git 拒绝更新已检出的分支（main）
git fetch --prune origin \
  '+refs/heads/*:refs/sync/heads/*' \
  '+refs/tags/*:refs/tags/*'

git remote remove gitcode 2>/dev/null || true
git remote add gitcode "$DEST"

say "推送到 GitCode: $OWNER/$REPO（分支+标签，强制覆盖，删除 GitCode 端多余引用）"
git "${AUTH[@]}" push --force --prune gitcode \
  '+refs/sync/heads/*:refs/heads/*' \
  '+refs/tags/*:refs/tags/*'

say "GITCODE_SYNC_DONE ($OWNER/$REPO)"
