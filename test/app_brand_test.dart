import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:xchat/core/app_brand.dart';

/// 品牌名（显示名）机制的一致性守护。
///
/// 改名版（SixChat）靠**构建期**注入，不改源码：
///   flutter build apk --release --dart-define=APP_BRAND_NAME=SixChat
/// 因此这里守住三件事：
///   1. 默认品牌名仍是 XChat；
///   2. 各平台（Android 启动器 / 桌面窗口标题 / 界面文案）都读同一个来源；
///   3. 打包脚本确实会多打一个改名版。
void main() {
  String read(String path) => File(path).readAsStringSync();

  test('默认品牌名是 XChat', () {
    expect(kAppBrandName, 'XChat');
    expect(kAppBrandSlug, 'xchat');
  });

  test('Android 启动器名称走 resValue（支持改名版注入）', () {
    final manifest = read('android/app/src/main/AndroidManifest.xml');
    expect(
      manifest,
      contains('android:label="@string/app_name"'),
      reason: 'AndroidManifest 必须用 @string/app_name，否则改名版不生效',
    );

    final gradle = read('android/app/build.gradle.kts');
    expect(gradle, contains('resValue("string", "app_name"'));
    expect(gradle, contains('APP_BRAND_NAME'));
    expect(
      gradle,
      contains('dart-defines'),
      reason: '品牌名应从 flutter 传入的 -Pdart-defines 解出',
    );
  });

  test('界面文案统一走 kAppBrandName', () {
    for (final path in const [
      'lib/app.dart',
      'lib/main.dart',
      'lib/ui/pages/home_page.dart',
      'lib/ui/pages/settings_page.dart',
    ]) {
      expect(read(path), contains('kAppBrandName'), reason: '$path 仍在硬编码应用名');
    }
  });

  test('桌面端原生窗口标题由 APP_BRAND_NAME 注入', () {
    expect(read('linux/CMakeLists.txt'), contains('APP_BRAND_NAME'));
    expect(read('linux/runner/my_application.cc'), contains('APP_BRAND_NAME'));
    expect(read('windows/CMakeLists.txt'), contains('APP_BRAND_NAME'));
    expect(read('windows/runner/main.cpp'), contains('APP_BRAND_NAME'));
  });

  test('打包脚本会多打一个改名版', () {
    for (final path in const [
      'dist/build_apk.sh',
      'dist/build_deb.sh',
      'dist/build_windows.ps1',
    ]) {
      final script = read(path);
      expect(script, contains('APP_BRAND_NAME'), reason: '$path 未注入改名版的品牌名');
      expect(
        script,
        contains('BRAND_VARIANT_NAME'),
        reason: '$path 未提供改名版名称开关',
      );
    }
  });
}
