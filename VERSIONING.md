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

**构建号与版本号绑定**：`x.y.z` 任一段发生变化 → 构建号**重置为 1**
（`0.7.7+3` → `0.7.8+1`）；只有版本号不变时构建号才在旧值上累加。
所以 `+N` 永远只描述"同一个版本号下第几次打包"。

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

**别手改，用脚本** `dist/bump_version.sh`（两处一起改、写完自校验）：

```sh
dist/bump_version.sh -s            # 显示当前版号（顺带提示两处是否已掉队）
dist/bump_version.sh               # 修订号 +1（0.7.7 -> 0.7.8），先确认再写
dist/bump_version.sh -c            # 同上，跳过确认
dist/bump_version.sh -z 3          # 修订号 +3
dist/bump_version.sh -y 1          # 次版本号 +1，修订号归 0（0.7.7 -> 0.8.0）
dist/bump_version.sh -y 1 -f       # 次版本号 +1，修订号不动（0.7.7 -> 0.8.7）
dist/bump_version.sh -x            # 主版本号 +1，次/修订归 0（0.7.7 -> 1.0.0）
dist/bump_version.sh -x -f         # 主版本号 +1，次/修订不动（0.7.7 -> 1.7.7）
dist/bump_version.sh -b 2          # 构建号 +2（+1 -> +3）
dist/bump_version.sh -c -y 1 -b 1  # 可组合
dist/bump_version.sh -d -b 1       # -d 直接赋值：构建号设为 1（0.7.7+5 -> 0.7.7+1）
dist/bump_version.sh -d -z 5       # 修订号设为 5（0.7.7 -> 0.7.5）
dist/bump_version.sh -d -x 2       # 主版本设为 2，次/修订归 0（0.7.7 -> 2.0.0）
dist/bump_version.sh -d -x 2 -f    # 主版本设为 2，其余不动（0.7.7 -> 2.7.7）
dist/bump_version.sh -m 1.2.3      # 直接把版号设为 1.2.3（构建号重置为 1）
dist/bump_version.sh -m 1.2.3 -b 1 # 版号变了 → 构建号仍是 1（-b 被忽略并提示）
```

- **归零规则**：升次版本（`-y`）时修订号归 0；升主版本（`-x`）时次版本与修订号都归 0。
  同一条命令里显式给出的段不归零（`-y 1 -z 2` → 修订号仍 +2）；`-f/--frozen`
  让本次升版完全不归零。
- **构建号规则**：`x.y.z` 任一段变化（含 `-m` 指定的版号与原版号不同）→ 构建号重置为
  `1`，此时给的 `-b N` 被忽略并打印提示；版号不变、只给 `-b N` → 构建号 `+= N`。
  想"新版本第 2 次打包"就分两步：先升版（得到 `+1`），再 `-b 1`（得到 `+2`）。
- `-d/--direct` 把 `-z/-y/-x/-b` 的参数从「增量」改成「绝对值」：给出的段**直接设为**该值
  （可以设成 0），没给出的段保持原值；归零规则照旧 —— `-d -y 2` 在次版本号**升高**时
  把修订号归 0（`-f` 关掉这条），下调或数字没变时其余段一律不动。
  `-d` 下的 `-b N` 是「把构建号设为 N」，优先于「版号变了就重置为 1」。
  `-d` 必须至少配一个 `-z/-y/-x/-b`，否则报错。
- `-x` 可以带数字（`-x 2` = 主版本 +2，`-d -x 2` = 主版本设为 2），不带时默认 `1`。
- `-m/--manual V` 直接把版号设为 `V`（`x.y.z`，可带前导 `v`），可再配 `-b`；
  不能与 `-z/-y/-x` 同用。
- 无升版参数（或只有 `-c`）= 修订号 +1；`-c` 之外缺省都要在终端确认。
- 非交互环境（CI / 脚本里）必须带 `-c`，否则直接退出码 2。

## 提醒：上架商店时构建号必须递增

当前规则是「版号一变，构建号回到 1」，也就是每个版本的第一次打包都是 `+1`——
桌面端无影响，但如果将来要上架 **Google Play / App Store**，这两个商店都要求构建号
（versionCode / CFBundleVersion）**跨版本严格递增**，届时必须改成全局计数器，
例如 `0.1.12+12`、`0.1.13+13`（把 `bump_version.sh` 的 `NEW_BUILD=1` 改成
`NEW_BUILD=BUILD+STEP_BUILD` 即可回到旧行为）。
