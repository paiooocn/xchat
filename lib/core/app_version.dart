/// 应用版本号的唯一来源（single source of truth）。
///
/// 必须与根目录 `pubspec.yaml` 的 `version: <版本>+<构建号>` 保持一致。
/// `test/app_version_test.dart` 会在两者不一致时失败，防止版本号再次掉队。
library;

/// 语义化版本号，对应 `pubspec.yaml` 中 `version:` 的 `+` 之前部分。
const String kAppVersion = '0.1.11';

/// 构建号，对应 `pubspec.yaml` 中 `version:` 的 `+` 之后部分。
const int kAppBuildNumber = 1;

/// 完整版本字符串，形如 `0.1.11+1`。
const String kAppVersionFull = '$kAppVersion+$kAppBuildNumber';
