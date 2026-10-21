#!/usr/bin/env bash
# 用 uv 下载 Python 3.12（独立可重定位发行版）到 third_party/python/，并做瘦身。
#
# 用法:
#   bash tool/fetch_python.sh                 # 装到 third_party/python/ 并裁剪
#   PY_VERSION=3.12 bash tool/fetch_python.sh # 指定版本
#   NO_TRIM=1 bash tool/fetch_python.sh       # 不裁剪（保留完整发行包）
#   UV_PYTHON_INSTALL_MIRROR=https://ghproxy.net/https://github.com/astral-sh/python-build-standalone/releases/download \
#     bash tool/fetch_python.sh               # 国内加速下载
#
# 说明:
# * uv 下载的是 python-build-standalone 发行版（可重定位、自带 stdlib 与 pip），
#   只借用 uv 的下载器与镜像能力，与 uv 自身的虚拟环境无关。
# * 安装目录形如 third_party/python/cpython-3.12.x-linux-x86_64-gnu/，
#   内含 bin/python3、lib/python3.12/；Windows 为 cpython-3.12.x-windows-x86_64-msvc/，
#   内含 python.exe、Lib/、DLLs/。
# * 打包时由 dist/build_deb.sh / dist/build_windows.ps1 拷进应用目录
#   <AppDir>/runtime/python/（见 docs/PYTHON_RUNTIME_PLAN.md §3）。
# * CI（.github/workflows/build-windows.yml 与 build-linux-deb.yml）也会调用本脚本。
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DEST="${DEST:-$ROOT/third_party/python}"
# 版本单一来源：tool/python_version.txt（精确到小版本，如 3.12.13）
PY_VERSION="${PY_VERSION:-$(tr -d '[:space:]' < "$ROOT/tool/python_version.txt")}"

if ! command -v uv >/dev/null 2>&1; then
  echo "!! 未找到 uv，请先安装： https://docs.astral.sh/uv/getting-started/installation/" >&2
  exit 1
fi

echo "==> uv: $(uv --version)"
echo "==> python $PY_VERSION -> $DEST"

mkdir -p "$DEST"

# --no-bin: 不往 uv 的 bin 目录写 shim；--no-registry: Windows 下不写注册表。
EXTRA=()
if [ "${OS:-}" = "Windows_NT" ]; then
  EXTRA+=(--no-registry)
fi

uv python install "$PY_VERSION" \
  --install-dir "$DEST" \
  --no-bin \
  "${EXTRA[@]+"${EXTRA[@]}"}"

# ---- 找到解释器根目录（必须是锁定的小版本）----
PY_ROOT=""
for d in "$DEST"/cpython-${PY_VERSION}-*/; do
  if [ -x "$d/bin/python3" ] || [ -x "$d/bin/python3.12" ] || [ -x "$d/python.exe" ]; then
    PY_ROOT="${d%/}"
    break
  fi
done
if [ -z "$PY_ROOT" ]; then
  echo "!! 未在 $DEST 下找到 cpython-${PY_VERSION}-* 解释器" >&2
  exit 1
fi
echo "==> runtime root: $PY_ROOT"

if [ -x "$PY_ROOT/bin/python3" ]; then
  PY_EXE="$PY_ROOT/bin/python3"
elif [ -x "$PY_ROOT/bin/python3.12" ]; then
  PY_EXE="$PY_ROOT/bin/python3.12"
else
  PY_EXE="$PY_ROOT/python.exe"
fi

# ---- Windows 侧补一个 python3.exe 别名 ----
# python-build-standalone 的 Windows 发行版只带 python.exe，Agent 统一按
# `python3 xxx.py` 书写（与 POSIX 一致），没有别名会直接 command not found。
if [ -f "$PY_ROOT/python.exe" ] && [ ! -f "$PY_ROOT/python3.exe" ]; then
  cp -f "$PY_ROOT/python.exe" "$PY_ROOT/python3.exe"
  echo "==> 已生成别名 python3.exe（指向 python.exe）"
fi

# ---- 瘦身：去掉运行时用不到的部分（头文件/文档/Tcl-Tk/IDLE/ensurepip/__pycache__）----
if [ "${NO_TRIM:-0}" != "1" ]; then
  echo "==> 裁剪运行时"
  rm -rf "$PY_ROOT/include" "$PY_ROOT/share" \
         "$PY_ROOT/Lib/ensurepip" "$PY_ROOT/tcl" "$PY_ROOT/tk" \
         "$PY_ROOT/lib/python3.12/idlelib" "$PY_ROOT/lib/python3.12/lib2to3" \
         "$PY_ROOT/lib/python3.12/tkinter" "$PY_ROOT/lib/python3.12/turtledemo" \
         "$PY_ROOT/lib/python3.12/ensurepip" "$PY_ROOT/lib/python3.12/pydoc_data" \
         "$PY_ROOT/lib/tcl"* "$PY_ROOT/lib/tk"* "$PY_ROOT/lib/thread3.0.4" \
         2>/dev/null || true
  find "$PY_ROOT" -type d -name '__pycache__' -prune -exec rm -rf {} + 2>/dev/null || true
  # 注意：不要对 python-build-standalone 的二进制做 strip。
  # 它的 ELF 布局特殊（strip 会报 "allocated section `.dynstr' not in segment"），
  # 裁剪后二进制会因符号版本信息缺失而无法启动（symbol lookup error）。
  # 需要更小体积时，改用 NO_TRIM=0 的目录裁剪即可。
fi

echo "==> 体积：$(du -sh "$PY_ROOT" | cut -f1)"

# ---- 自检：解释器与 pip 仍可用，且版本与锁定值一致 ----
GOT_VERSION="$("$PY_EXE" -c 'import sys;print(sys.version.split()[0])')"
"$PY_EXE" -c 'import sys, ssl, sqlite3, lzma, ctypes, json, zipfile, xml.etree.ElementTree; print("python ok:", sys.version.split()[0])'
PYTHONNOUSERSITE=1 "$PY_EXE" -m pip --version
if [ "$GOT_VERSION" != "$PY_VERSION" ]; then
  echo "!! 版本不符：期望 $PY_VERSION，实际 $GOT_VERSION" >&2
  exit 1
fi
echo "==> 版本校验通过：$GOT_VERSION"

echo "==> FETCH_DONE"
