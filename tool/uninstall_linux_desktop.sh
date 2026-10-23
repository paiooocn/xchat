#!/usr/bin/env bash
# 清理 XChat 早期版本在**用户目录**里留下的桌面集成残留。
#
# 背景：旧版 tool/install_linux_desktop.sh 与旧版 linux/runner 曾在
# ~/.local/share/icons/hicolor/ 写一份自己的 index.theme。用户级图标目录
# 优先级高于 /usr/share/icons/hicolor，那份 index.theme 会整体顶替系统
# hicolor 主题（系统上千个图标只剩自己声明的几个），于是全桌面图标兜底
# 失效，开始菜单里大量条目变成空白 / 齿轮，甚至点不开。
#
# 现在桌面集成只由**打包安装**提供（deb / CMake install），应用运行时不再
# 写用户目录，因此本脚本只负责「删残留」，不做任何安装动作。
#
# 用法：bash tool/uninstall_linux_desktop.sh
set -euo pipefail

APP_ID=com.yimo.xchat
APPS_DIR="$HOME/.local/share/applications"
THEME_DIR="$HOME/.local/share/icons/hicolor"

# 1) 旧版写下的用户级 .desktop 条目
if [ -f "$APPS_DIR/$APP_ID.desktop" ]; then
  echo "删除用户级条目 $APPS_DIR/$APP_ID.desktop"
  rm -f "$APPS_DIR/$APP_ID.desktop"
fi

# 2) 旧版放进用户图标目录的图标文件（纯新增文件，删掉不影响系统主题）
icon="$THEME_DIR/256x256/apps/$APP_ID.png"
if [ -f "$icon" ]; then
  echo "删除用户级图标 $icon"
  rm -f "$icon"
fi

# 3) 旧版写的伪 hicolor 索引：只在特征串完全匹配时才删，避免误伤用户自己的主题
index="$THEME_DIR/index.theme"
if [ -f "$index" ] \
   && grep -q '^Comment=Fallback icon theme' "$index" \
   && grep -q '^Directories=256x256/apps' "$index"; then
  echo "删除伪 hicolor 索引 $index（它会顶替系统 hicolor 图标主题）"
  rm -f "$index" "$THEME_DIR/icon-theme.cache"
fi

echo "清理完成。现在可以重新安装（deb 或 CMake install）以获得正确的桌面条目。"
