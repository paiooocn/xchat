# 版本号说明（version + build number）

`pubspec.yaml` 中的版本号格式：

```
version: <版本号>+<构建号>
         0.1.11 + 1
```

其中 `+1` 是**构建号（build number）**。两部分的含义：

| 部分 | 本例 | 作用 |
|---|---|---|
| `0.1.11` | 语义化版本（semver） | 面向用户的版本，遵循 `主版本.次版本.修订号`，表示功能/修复的演进 |
| `+1` | 构建号 | 面向平台/商店的构建序号，标识"同一次发布重新打包了多少回" |

## 注入到平台产物

两部分都会被 Flutter 构建注入到各平台产物里：

- **Android**：`versionName = 0.1.11`、`versionCode = 1`
  （见 `android/app/build.gradle.kts` 中的 `flutter.versionName` / `flutter.versionCode`）
- **iOS / macOS**：`CFBundleShortVersionString = 0.1.11`、`CFBundleVersion = 1`
- **Windows**：`windows/runner/Runner.rc` 的 `VERSION_AS_NUMBER` / `VERSION_AS_STRING` 用到全部四段

## 什么时候会变

- **版本号变**：功能更新、bug 修复发布 → `0.1.11` → `0.1.12`
- **构建号变**：同一个版本号下重新打包（如商店审核被拒后重传、仅重新构建签名包）
  → `0.1.11+1` → `0.1.11+2`

## 在代码中的唯一来源

应用内显示的版本（如设置页页脚）不再硬编码，统一取自
[`lib/core/app_version.dart`](lib/core/app_version.dart)：

```dart
const String kAppVersion = '0.1.11';      // 版本号（+ 之前）
const int kAppBuildNumber = 1;            // 构建号（+ 之后）
const String kAppVersionFull = '$kAppVersion+$kAppBuildNumber'; // 0.1.11+1
```

`test/app_version_test.dart` 是一致性守护：它解析 `pubspec.yaml` 的 `version`
字段并与 `kAppVersionFull` 比较，两者不一致时测试直接失败。

**发版时需同步修改两处**（测试会兜底防漏）：

1. `pubspec.yaml` 的 `version:`
2. `lib/core/app_version.dart` 的 `kAppVersion` / `kAppBuildNumber`

## 提醒：上架商店时构建号必须递增

仓库历史从 v0.1.5 起每次发版都是 `X.Y.Z+1`，构建号从未变过，桌面端无影响。
但如果将来要上架 **Google Play / App Store**，这两个商店都要求构建号
（对应 versionCode / CFBundleVersion）严格递增——届时建议随发版递增，例如
`0.1.12+2`、`0.1.13+3`。
