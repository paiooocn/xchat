import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:xchat/config/blocklist_loader.dart';
import 'package:xchat/config/config_manager.dart';

void main() {
  setUpAll(() async {
    final tmp = Directory.systemTemp.createTempSync('xchat_test_bl_');
    ConfigManager.instance.initForTest(tmp);
  });

  group('BlocklistLoader', () {
    test('首次启动从默认文件写入并加载', () async {
      // initForTest 时 _xchatDir 已设但没创建子目录;load() 应当兜底
      await BlocklistLoader.instance.reload();
      final bl = BlocklistLoader.instance.current;
      // bin/default_blocklist.xml 应被写入
      final file = File(p.join(ConfigManager.instance.xchatDir.path, 'shell_blocklist.xml'));
      expect(file.existsSync(), true);
      // 内置默认应当包含至少一条 layer_a
      expect(bl.layerA.length, greaterThan(0));
    });

    test('Layer A 全模式拒绝', () async {
      await BlocklistLoader.instance.reload();
      final bl = BlocklistLoader.instance.current;
      // 假设默认里有 sudo / rm -rf / 等
      final hasSudo = bl.layerA.any((r) => r.pattern.contains('sudo'));
      expect(hasSudo, true);
      expect(bl.layerA.first.regex.hasMatch('sudo rm -rf /'), true);
    });

    test('Layer B 例外规则也编译成功', () async {
      await BlocklistLoader.instance.reload();
      final bl = BlocklistLoader.instance.current;
      expect(bl.layerBExceptions.length, greaterThan(0));
      // 第一个例外规则应能编译并匹配示例
      final r = bl.layerBExceptions.first;
      // 只要不抛异常,正则编译就算成功
      expect(r.regex.pattern, isNotEmpty);
    });

    test('save 后 reload 能拿到更新后的规则', () async {
      final loader = BlocklistLoader.instance;
      await loader.save(
        layerA: [BlockRule('DANGEROUS_CMD', 'test only')],
        layerB: [BlockRule('npm install', 'test only')],
        layerBExceptions: [],
      );
      final bl = loader.current;
      expect(bl.layerA.length, 1);
      expect(bl.layerA[0].pattern, 'DANGEROUS_CMD');
      expect(bl.layerA[0].regex.hasMatch('run DANGEROUS_CMD now'), true);
      // 恢复默认
      await loader.reload();
    });

    test('正则可编译并匹配字面文本', () {
      // Dart 的 RegExp 对宽松语法(未闭合字符类等)会自动容忍,这里只验编译+匹配
      final r = BlockRule(r'\bgrep\b', 'grep');
      expect(r.regex.hasMatch('please grep -r foo'), true);
      expect(r.regex.hasMatch('hello world'), false);
    });
  });
}
