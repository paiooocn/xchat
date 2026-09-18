/// Minimal, predictable XML writer: every element's text is emitted as CDATA
/// and *never* entity-escaped. Avoids the whitespace injection that a
/// generic pretty-printer applies to CDATA nodes.
class XmlOut {
  XmlOut();

  final StringBuffer _buffer = StringBuffer();
  int _depth = 0;
  static const _indent = '  ';

  void declaration() => _buffer.writeln('<?xml version="1.0" encoding="UTF-8"?>');

  /// `<name attrs>` … children … `</name>`.
  void open(String name, [Map<String, String> attributes = const {}]) {
    _buffer.writeln('${_pad()}<$name${_attrs(attributes)}>');
    _depth++;
  }

  void close(String name) {
    _depth--;
    _buffer.writeln('${_pad()}</$name>');
  }

  /// A leaf element whose text is written as CDATA.
  void leaf(String name, String? text, [Map<String, String> attributes = const {}]) {
    _buffer.write('${_pad()}<$name${_attrs(attributes)}>');
    _buffer.write(_cdata(text ?? ''));
    _buffer.writeln('</$name>');
  }

  /// A leaf element whose text is emitted as plain, entity-escaped text
  /// (no CDATA). Used for machine-readable / structured fields such as
  /// `meta/*`, `provider`, `model`, `thinking_reply_mode` and `tool`.
  void leafText(String name, String? text, [Map<String, String> attributes = const {}]) {
    _buffer.write('${_pad()}<$name${_attrs(attributes)}>');
    _buffer.write(_escapeText(text ?? ''));
    _buffer.writeln('</$name>');
  }

  String build() => _buffer.toString();

  String _pad() => _indent * _depth;

  static String _attrs(Map<String, String> attributes) {
    if (attributes.isEmpty) return '';
    final buffer = StringBuffer();
    attributes.forEach((key, value) {
      buffer.write(' $key="${_escapeAttr(value)}"');
    });
    return buffer.toString();
  }

  static String _escapeAttr(String value) => value
      .replaceAll('&', '&amp;')
      .replaceAll('<', '&lt;')
      .replaceAll('"', '&quot;')
      .replaceAll('\r', '&#13;')
      .replaceAll('\n', '&#10;');

  static String _escapeText(String value) => value
      .replaceAll('&', '&amp;')
      .replaceAll('<', '&lt;')
      .replaceAll('>', '&gt;');

  /// Wraps [text] in CDATA, splitting any embedded `]]>` sequences.
  static String _cdata(String text) {
    final safe = text.replaceAll(']]>', ']]]]><![CDATA[>');
    return '<![CDATA[$safe]]>';
  }
}
