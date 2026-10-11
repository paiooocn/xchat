# Build the Windows release bundle and package it as dist/xchat-windows-x64-v{x.y.z}.zip.
# 用法（Windows，任意终端；也可右键「使用 PowerShell 运行」）:
#   powershell -NoProfile -ExecutionPolicy Bypass -File dist\build_windows.ps1
#   pwsh -NoProfile -File dist\build_windows.ps1
# 环境变量覆盖: PROJ(项目根) / FLUTTER_BIN(flutter\bin 目录) / ARCH(默认 x64)
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

# ---- 构建 ----
flutter build windows --release
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

# ---- 打包（与 CI build-windows.yml 相同的 Compress-Archive）----
New-Item -ItemType Directory -Force -Path dist | Out-Null
$Dest = "dist\xchat-windows-$Arch-v$Version.zip"
if (Test-Path $Dest) { Remove-Item $Dest -Force }
Compress-Archive -Path (Join-Path $Bundle '*') -DestinationPath $Dest -Force

Write-Host "==> built $Dest"
Get-Item $Dest | Format-Table Name, Length, LastWriteTime -AutoSize

# 仅保留当前与上一次打包的 zip：按修改时间保留最新 2 个，删除更旧的。
Get-ChildItem dist -Filter 'xchat-windows-*.zip' |
  Sort-Object LastWriteTime -Descending |
  Select-Object -Skip 2 |
  ForEach-Object {
    Write-Host "==> pruning old artifact: $($_.Name)"
    Remove-Item $_.FullName -Force
  }

Write-Host '==> BUILD_DONE'
