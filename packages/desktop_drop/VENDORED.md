# desktop_drop（vendored）

来源：`https://pub.dev/packages/desktop_drop` **0.8.4**（`~/.pub-cache/hosted/pub.dev/desktop_drop-0.8.4`）。
除下面这一处，所有文件与上游逐字相同（`example/` 与 `test/` 未拷贝）。

## 为什么 vendor

`flutter build apk` 每次都会打印：

```
WARNING: Your app uses the following plugins that apply Kotlin Gradle Plugin (KGP): desktop_drop
```

Flutter 的检查（`packages/flutter_tools/gradle/.../FlutterPluginUtils.kt` 的
`detectApplyingKotlinGradlePlugin` + `kgpRegexGroovy`）是**对 `android/build.gradle`
文本做正则扫描**，只要出现行首的 `apply plugin: 'kotlin-android'` 就记一笔 ——
0.8.4 虽然已经用「AGP >= 9 则不 apply」把它包在条件里，文本仍然命中，于是误报。
上游没有更新的版本可以去掉这行，所以这里 vendor 一份。

## 与上游的唯一差异

`android/build.gradle` 里的

```groovy
apply plugin: 'kotlin-android'
```

改成功能等价的

```groovy
pluginManager.apply("kotlin-android")
```

顺带补了 `apply plugin: 'com.android.library'`（上游写在 `kotlin-android` 之后，
两者顺序不影响结果）。行为不变：
- 本仓库现在 `android.builtInKotlin=false` → 仍然 apply KGP，编译方式与之前完全一样；
- 将来内置 Kotlin 成为默认 → 不 apply，走 AGP 内置 Kotlin。

## 维护

上游发新版本时：比对 `lib/` 与三套桌面原生目录，把差异合进来，然后**确认
`android/build.gradle` 里没有再出现行首的 `apply plugin: 'kotlin-android'`**
（否则警告回来）。见 `.memory/GOTCHAS.md` §31。
