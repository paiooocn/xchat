import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:xchat/core/app_version.dart';

/// 版本号一致性守护：
/// `lib/core/app_version.dart` 必须与 `pubspec.yaml` 的 `version` 字段一致，
/// 否则设置页页脚等处显示的版本会与实际发布版本脱节。
void main() {
  test('kAppVersion 与 pubspec.yaml 的 version 一致', () {
    final yaml = File('pubspec.yaml').readAsStringSync();
    final match = RegExp(r'^version:\s*(\S+)\s*$', multiLine: true).firstMatch(yaml);
    expect(match, isNotNull, reason: 'pubspec.yaml 中找不到 version 字段');

    final pubspecVersion = match!.group(1)!; // 形如 0.1.10+1
    expect(
      kAppVersionFull,
      pubspecVersion,
      reason: '版本号掉队了：请同步修改 lib/core/app_version.dart 与 pubspec.yaml',
    );

    final parts = pubspecVersion.split('+');
    expect(kAppVersion, parts.first, reason: '语义化版本号与 pubspec.yaml 不一致');
    if (parts.length > 1) {
      expect(kAppBuildNumber.toString(), parts[1], reason: '构建号与 pubspec.yaml 不一致');
    }
  });
}
