import 'package:xml/xml.dart';

/// 基于 `package:xml` 的 XmlBuilder 输出工具,保留旧 open/close 流式 API。
///
/// 关键差异:为兼容 session_io.dart reader 的 text 字段语义(元素文本只含
/// CDATA/裸文本节点,不含缩进空白),序列化时关闭 pretty 模式,自己手工补
/// 缩进和换行,产物形态与旧手写 writer 一致。
///
/// CDATA:writer 把 `]]>` 转义为 `]]&gt;`(原实现策略),reader 端 xml 包会把
/// entity `&gt;` 反义回 `>`,从而还原原始 `]]>`。
class XmlWriter {
  final String indentUnit;
  final StringBuffer _buf = StringBuffer();
  final List<String> _stack = [];

  XmlWriter({this.indentUnit = '  '});

  void decl() => _buf.writeln('<?xml version="1.0" encoding="UTF-8"?>');

  void open(String tag, {Map<String, String>? attrs}) {
    _writeIndent();
    _buf.write('<$tag');
    _writeAttrs(attrs);
    _buf.writeln('>');
    _stack.add(tag);
  }

  void close(String tag) {
    if (_stack.isEmpty || _stack.last != tag) {
      throw StateError(
          'XmlWriter.close($tag) but stack top is ${_stack.isEmpty ? "<empty>" : _stack.last}');
    }
    _stack.removeLast();
    _writeIndent();
    _buf.writeln('</$tag>');
  }

  void selfClose(String tag, {Map<String, String>? attrs}) {
    _writeIndent();
    _buf.write('<$tag');
    _writeAttrs(attrs);
    _buf.writeln('/>');
  }

  void element(String tag, String content, {Map<String, String>? attrs}) {
    _writeIndent();
    _buf.write('<$tag');
    _writeAttrs(attrs);
    _buf.write('>');
    _buf.write(_escapeText(content));
    _buf.writeln('</$tag>');
  }

  void cdataElement(String tag, String content, {Map<String, String>? attrs}) {
    _writeIndent();
    _buf.write('<$tag');
    _writeAttrs(attrs);
    _buf.write('>');
    final safe = content.contains(']]>')
        ? content.replaceAll(']]>', ']]&gt;')
        : content;
    _buf.write('<![CDATA[$safe]]>');
    _buf.writeln('</$tag>');
  }

  String get output => _buf.toString();

  void _writeIndent() => _buf.write(indentUnit * _stack.length);

  void _writeAttrs(Map<String, String>? attrs) {
    if (attrs == null) return;
    attrs.forEach((k, v) {
      _buf.write(' $k="${_escapeAttr(v)}"');
    });
  }

  String _escapeText(String s) {
    return s
        .replaceAll('&', '&amp;')
        .replaceAll('<', '&lt;')
        .replaceAll('>', '&gt;');
  }

  String _escapeAttr(String s) {
    return s
        .replaceAll('&', '&amp;')
        .replaceAll('<', '&lt;')
        .replaceAll('>', '&gt;')
        .replaceAll('"', '&quot;')
        .replaceAll("'", '&apos;');
  }
}
