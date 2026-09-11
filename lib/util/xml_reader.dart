import 'package:xml/xml.dart' as pkg;

/// 轻量 XML 元素树,作为 `package:xml` 与 session_io.dart 解析逻辑之间的适配层。
/// 保留旧 API:tag / attrs / children / text,以及 attr(name, fallback) 读取器,
/// 这样 _parseChat 不需要重写。
class XmlElement {
  final String tag;
  final Map<String, String> attrs;
  final List<XmlElement> children;
  final String text;

  XmlElement({
    required this.tag,
    Map<String, String>? attrs,
    List<XmlElement>? children,
    this.text = '',
  })  : attrs = attrs ?? {},
        children = children ?? [];

  String attr(String name, {String fallback = ''}) => attrs[name] ?? fallback;
}

class XmlParseException implements Exception {
  final String message;
  XmlParseException(this.message);
  @override
  String toString() => 'XmlParseException: $message';
}

/// 基于 `package:xml` 的解析器。XmlDocument.parse 负责 XML 声明/注释/CDATA/
/// 实体引用/属性转义等所有合规 XML 语法;这里把 pkg.XmlElement 转成项目内部的
/// XmlElement 树,并把所有子节点(文本、CDATA、嵌套元素)的纯文本合并到 text。
class XmlReader {
  static XmlElement parse(String input) {
    final pkg.XmlDocument doc;
    try {
      doc = pkg.XmlDocument.parse(input);
    } on pkg.XmlException catch (e) {
      throw XmlParseException(e.toString());
    }
    return _convert(doc.rootElement);
  }

  static XmlElement _convert(pkg.XmlElement src) {
    final attrs = <String, String>{};
    for (final a in src.attributes) {
      attrs[a.name.local] = a.value;
    }
    final children = <XmlElement>[];
    final buf = StringBuffer();
    for (final node in src.children) {
      switch (node.nodeType) {
        case pkg.XmlNodeType.CDATA:
        case pkg.XmlNodeType.TEXT:
          // CDATA 内 entity 不被 xml 包解析,但 writer 把 ]]> 转义为 ]]&gt;
          // 后才放入 CDATA,这里反义回 ]]> 以还原原内容。
          buf.write(node.text.replaceAll(']]&gt;', ']]>'));
          break;
        case pkg.XmlNodeType.ELEMENT:
          final sub = _convert(node as pkg.XmlElement);
          // 嵌套元素只走 children,文本不进 text(与原手写实现一致:
          // text 只累积元素之间的字符数据,不递归下钻到子元素)。
          children.add(sub);
          break;
        default:
          // 注释/PI 等忽略。
          break;
      }
    }
    return XmlElement(
      tag: src.name.local,
      attrs: attrs,
      children: children,
      text: buf.toString(),
    );
  }
}
