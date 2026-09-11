import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:xml/xml.dart';

import 'config_manager.dart';

class BlockRule {
  final String pattern;
  final String note;
  BlockRule(this.pattern, this.note);
  late final RegExp regex = RegExp(pattern);
}

class Blocklist {
  final List<BlockRule> layerA;
  final List<BlockRule> layerB;
  final List<BlockRule> layerBExceptions;

  Blocklist({
    required this.layerA,
    required this.layerB,
    required this.layerBExceptions,
  });

  static Blocklist empty() =>
      Blocklist(layerA: [], layerB: [], layerBExceptions: []);

  String describeLayerA() => layerA.map((r) => r.note).join('; ');
  String describeLayerB() => layerB.map((r) => r.note).join('; ');
}

/// 单例：启动时加载一次，提供热重载
class BlocklistLoader {
  BlocklistLoader._();
  static final BlocklistLoader instance = BlocklistLoader._();

  Blocklist _current = Blocklist.empty();
  bool _loaded = false;
  String? _path;

  String get path => _path ?? '(未加载)';
  Blocklist get current => _current;
  bool get loaded => _loaded;

  /// 加载：缺失则写入默认文件后再加载
  Future<void> load() async {
    final dir = ConfigManager.instance.xchatDir;
    _path = p.join(dir.path, 'shell_blocklist.xml');
    final file = File(_path!);

    if (!await file.exists()) {
      // 拷贝默认 blocklist
      const defaultPath = 'bin/default_blocklist.xml';
      final src = File(defaultPath);
      if (await src.exists()) {
        await file.writeAsBytes(await src.readAsBytes());
      } else {
        // 兜底：用内置默认字符串
        await file.writeAsString(_builtinDefault());
      }
    }

    final xmlStr = await file.readAsString();
    _current = _parse(xmlStr);
    _loaded = true;
  }

  /// 热重载
  Future<void> reload() async {
    _loaded = false;
    await load();
  }

  Blocklist _parse(String xmlStr) {
    final doc = XmlDocument.parse(xmlStr);

    List<BlockRule> readLayer(String tag) {
      final node = doc.rootElement.findElements(tag).firstOrNull;
      if (node == null) return [];
      return node.findElements('rule').map((r) {
        final pat = r.getAttribute('pattern') ?? '';
        final note = r.getAttribute('note') ?? '';
        return BlockRule(pat, note);
      }).toList();
    }

    return Blocklist(
      layerA: readLayer('layer_a'),
      layerB: readLayer('layer_b'),
      layerBExceptions: readLayer('layer_b_exceptions'),
    );
  }

  String _builtinDefault() {
    return '''<?xml version="1.0" encoding="UTF-8"?>
<shell_blocklist version="1">
  <layer_a name="完全禁止"/>
  <layer_b name="需授权"/>
  <layer_b_exceptions name="yolo 拒绝但其他模式允许"/>
</shell_blocklist>
''';
  }

  /// 写入（用户编辑保存）
  Future<void> save({
    required List<BlockRule> layerA,
    required List<BlockRule> layerB,
    required List<BlockRule> layerBExceptions,
  }) async {
    final b = XmlBuilder();
    b.processing('xml', 'version="1.0" encoding="UTF-8"');
    b.element('shell_blocklist', nest: () {
      b.attribute('version', '1');
      _writeLayer(b, 'layer_a', '完全禁止', layerA);
      _writeLayer(b, 'layer_b', '需授权', layerB);
      _writeLayer(b, 'layer_b_exceptions', 'yolo 拒绝但其他模式允许', layerBExceptions);
    });
    final out = b.buildDocument().toXmlString(pretty: true, indent: '  ');
    final file = File(_path!);
    await file.writeAsString(out, flush: true);
    await reload();
  }

  void _writeLayer(
      XmlBuilder b, String tag, String name, List<BlockRule> rules) {
    b.element(tag, nest: () {
      b.attribute('name', name);
      for (final r in rules) {
        b.element('rule', nest: () {
          b.attribute('pattern', r.pattern);
          b.attribute('note', r.note);
        });
      }
    });
  }
}

extension on Iterable<XmlElement> {
  XmlElement? get firstOrNull {
    final it = iterator;
    if (!it.moveNext()) return null;
    return it.current;
  }
}
