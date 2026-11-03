# Build the Windows release bundle and package it as dist/{slug}-windows-x64-v{x.y.z}.zip.
# 用法（Windows，任意终端；也可右键「使用 PowerShell 运行」）:
#   powershell -NoProfile -ExecutionPolicy Bypass -File dist\build_windows.ps1
#   pwsh -NoProfile -File dist\build_windows.ps1
# 环境变量覆盖: PROJ(项目根) / FLUTTER_BIN(flutter\bin 目录) / ARCH(默认 x64)
#                BRAND_VARIANT_NAME(改名版显示名，默认 SixChat) / BUILD_BRAND_VARIANT(0 = 不打改名版)
$ErrorActionPreference = 'Stop'

# ---- 定位项目根（与 build_deb.sh 的 SCRIPT_DIR/PROJ 约定一致）----
$ScriptDir = $PSScriptRoot
if (-not $ScriptDir) { $ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path }
$Proj = if ($env:PROJ) { $env:PROJ } else { (Resolve-Path (Join-Path $ScriptDir '..')).Path }

if ($env:FLUTTER_BIN) { $env:Path = "$env:FLUTTER_BIN;$env:Path" }

Set-Location $Proj

# ---- 版本号：pubspec.yaml 的 version: x.y.z+build，取 x.y.z ----
$verRaw = (Select-String -Path pubspec.yaml -Pattern '^version:\s*(.+)$' |
  Select-Object -First 1).Matches[0].Groups[1].Value.Trim()
$Version = $verRaw.Split('+')[0]
$Arch = if ($env:ARCH) { $env:ARCH } else { 'x64' }
Write-Host "==> app version: v$Version  arch: $Arch"

# ---- 改名版：只改显示名，默认 SixChat ----
$VariantName = if ($env:BRAND_VARIANT_NAME) { $env:BRAND_VARIANT_NAME } else { 'SixChat' }
$VariantSlug = ($VariantName.ToLower() -replace '[^a-z0-9-]', '')
if (-not $VariantSlug) { $VariantSlug = 'variant' }

function Build-Zip {
  param([string]$Brand, [string]$Slug)

  Write-Host "==> building windows bundle: $Brand"
  # 窗口标题由 CMake 从环境变量 APP_BRAND_NAME 读，Dart 侧用 --dart-define，
  # 两者必须同名。删掉 build\windows 让 CMake 重新 configure（否则缓存里
  # 还是上一次的显示名）。
  if (Test-Path 'build\windows') { Remove-Item -Recurse -Force 'build\windows' }
  $env:APP_BRAND_NAME = $Brand
  flutter build windows --release --dart-define="APP_BRAND_NAME=$Brand"
  if ($LASTEXITCODE -ne 0) { throw "flutter build windows failed (exit $LASTEXITCODE)" }

  # ---- 定位产物目录（标准路径找不到时回退搜索 xchat.exe）----
  $Bundle = "build\windows\$Arch\runner\Release"
  if (-not (Test-Path (Join-Path $Bundle 'xchat.exe'))) {
    $exe = Get-ChildItem -Path 'build\windows' -Recurse -Filter 'xchat.exe' -ErrorAction SilentlyContinue |
      Where-Object { $_.FullName -match 'Release' } | Select-Object -First 1
    if ($exe) { $Bundle = $exe.DirectoryName }
  }
  if (-not (Test-Path (Join-Path $Bundle 'xchat.exe'))) { throw "windows bundle not found (xchat.exe)" }
  Write-Host "==> bundle: $Bundle"

  # ---- 内置 Python（tool/fetch_python.sh 下载后拷入 <Bundle>\runtime\python）----
  # 版本单一来源：tool\python_version.txt（如 3.12.13）
  $PyVerFile = Join-Path $Proj 'tool\python_version.txt'
  $PyVer = if (Test-Path $PyVerFile) { (Get-Content $PyVerFile -Raw).Trim() } else { '3.12.13' }
  $PySrc = Get-ChildItem -Path (Join-Path $Proj 'third_party\python') -Directory -ErrorAction SilentlyContinue |
    Where-Object { $_.Name -like "cpython-$PyVer-*" } | Select-Object -First 1
  if ($PySrc) {
    $PyDest = Join-Path $Bundle 'runtime\python'
    New-Item -ItemType Directory -Force -Path $PyDest | Out-Null
    Copy-Item -Path (Join-Path $PySrc.FullName '*') -Destination $PyDest -Recurse -Force
    # Windows 发行版只带 python.exe，Agent 统一写 `python3 xxx.py`：补一个同名别名。
    $PyExe = Join-Path $PyDest 'python.exe'
    $Py3Exe = Join-Path $PyDest 'python3.exe'
    if ((Test-Path $PyExe) -and (-not (Test-Path $Py3Exe))) {
      Copy-Item -Path $PyExe -Destination $Py3Exe -Force
      Write-Host '==> 已生成别名 python3.exe'
    }
    Write-Host "==> bundled python: $($PySrc.FullName)"
  } else {
    Write-Host "!! 未找到 third_party\python\cpython-$PyVer-*，本次不带内置 Python"
  }

  # ---- 打包（与 CI build-windows.yml 相同的 Compress-Archive）----
  New-Item -ItemType Directory -Force -Path dist | Out-Null
  $Dest = "dist\$Slug-windows-$Arch-v$Version.zip"
  if (Test-Path $Dest) { Remove-Item $Dest -Force }
  Compress-Archive -Path (Join-Path $Bundle '*') -DestinationPath $Dest -Force

  Write-Host "==> built $Dest"
  Get-Item $Dest | Format-Table Name, Length, LastWriteTime -AutoSize
}

Build-Zip -Brand 'XChat' -Slug 'xchat'
if ($env:BUILD_BRAND_VARIANT -ne '0') {
  Build-Zip -Brand $VariantName -Slug $VariantSlug
}

# 仅保留当前与上一次打包的 zip：按修改时间保留最新 2 个，删除更旧的。
function Remove-OldZips {
  param([string]$Pattern)
  Get-ChildItem dist -Filter $Pattern |
    Sort-Object LastWriteTime -Descending |
    Select-Object -Skip 2 |
    ForEach-Object {
      Write-Host "==> pruning old artifact: $($_.Name)"
      Remove-Item $_.FullName -Force
    }
}
Remove-OldZips 'xchat-windows-*.zip'
if ($env:BUILD_BRAND_VARIANT -ne '0') { Remove-OldZips "$VariantSlug-windows-*.zip" }

Write-Host '==> BUILD_DONE'
