/// 应用显示名的**唯一来源**。
///
/// 默认值是 `XChat`（正式版）。改名版（如 `SixChat`）在**构建期**注入，
/// 源码不需要改动：
///
/// ```sh
/// # Android：flutter 会把 --dart-define 编进 -Pdart-defines，
/// # android/app/build.gradle.kts 解出它写入 resValue("string", "app_name")
/// flutter build apk --release --dart-define=APP_BRAND_NAME=SixChat
///
/// # 桌面端：原生窗口标题不读 Dart 常量，CMake 从同名环境变量取值，
/// # 所以桌面端要同时给环境变量
/// APP_BRAND_NAME=SixChat flutter build linux --release \
///   --dart-define=APP_BRAND_NAME=SixChat
/// ```
///
/// 注意：改名只改「显示名」。包名 / applicationId / 数据目录等**身份标识不变**，
/// 因此改名版与正式版是同一个应用（后装的覆盖先装的，数据目录共用）。
const String kAppBrandName = String.fromEnvironment(
  'APP_BRAND_NAME',
  defaultValue: 'XChat',
);

/// 品牌名对应的产物标识（小写、只留字母数字与短横线），用于文件名前缀，
/// 例如 `sixchat-v0.6.12.apk`。
String get kAppBrandSlug {
  final slug = kAppBrandName
      .trim()
      .toLowerCase()
      .replaceAll(RegExp('[^a-z0-9]+'), '-')
      .replaceAll(RegExp(r'^-+|-+$'), '');
  return slug.isEmpty ? 'xchat' : slug;
}
