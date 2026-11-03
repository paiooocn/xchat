# 改名版打包（XChat → SixChat）

一句话：**每次 build 会多打一个只改应用名的版本**，源码不用动。

```sh
bash dist/build_apk.sh      # → dist/xchat-vX.Y.Z.apk  +  dist/sixchat-vX.Y.Z.apk
bash dist/build_deb.sh      # → dist/xchat-vX.Y.Z.deb  +  dist/sixchat-vX.Y.Z.deb
powershell -File dist\build_windows.ps1   # → 两个 zip
```

CI（Android / Linux / Windows 三个工作流）跑的就是这几个脚本，产物会一并
上传到 artifact 并附加到 Release。

## 开关

| 环境变量 | 默认 | 作用 |
|---|---|---|
| `BRAND_VARIANT_NAME` | `SixChat` | 改名版的显示名（同时决定产物文件名前缀） |
| `BUILD_BRAND_VARIANT` | `1` | 设为 `0` 则只打正式版，不打改名版 |

```sh
BRAND_VARIANT_NAME=MyChat BUILD_BRAND_VARIANT=0 bash dist/build_apk.sh
```

## 手工打单个改名版

```sh
# Android（启动器图标下的名字 + 界面文案）
flutter build apk --release --dart-define=APP_BRAND_NAME=SixChat

# Linux（窗口标题 + .desktop 条目名 + 界面文案）
# 桌面端的原生标题走 CMake（环境变量），必须和 --dart-define 同名；
# 删掉 build/linux 是为了让 CMake 重新 configure（否则缓存里还是旧名字）。
rm -rf build/linux
APP_BRAND_NAME=SixChat flutter build linux --release --dart-define=APP_BRAND_NAME=SixChat

# Windows（窗口标题 + 界面文案）
rm -rf build/windows
APP_BRAND_NAME=SixChat flutter build windows --release --dart-define=APP_BRAND_NAME=SixChat
```

## 改名了哪些东西

| 位置 | 怎么来的 |
|---|---|
| 界面文案（窗口标题 / 侧栏品牌行 / 欢迎页 / 关于页） | `lib/core/app_brand.dart` 的 `kAppBrandName` |
| Android 启动器名字 | `android/app/build.gradle.kts` 解 `-Pdart-defines` → `resValue("string","app_name")` |
| Linux 窗口标题 / `.desktop` 的 `Name` | CMake 从环境变量 `APP_BRAND_NAME` 取 → 编译宏 |
| Windows 窗口标题 | 同上（宽串） |

**没改**（刻意不改）：`applicationId`（`com.yimo.xchat`）、deb 包名与安装路径、
数据目录、版本号、图标与品牌标记（还是「X」）。

> 因此改名版与正式版**不能共存**：同一个 applicationId，装谁覆盖谁，
> 数据目录共用。要让两者并存，需要另开 applicationId / 包名 / 数据目录，
> 那是另一件事（改动面很大，暂未做）。
