import 'package:xml/xml.dart';

/// Builds `<name><![CDATA[text]]></name>` — text is never entity-escaped.
void cdataElement(
  XmlBuilder builder,
  String name,
  String? text, {
  Map<String, String> attributes = const <String, String>{},
}) {
  builder.element(name, attributes: attributes, nest: () {
    builder.cdata(text ?? '');
  });
}

/// Reads an element's text (folds CDATA + text nodes); `null` when absent.
String? readText(XmlElement parent, String name) {
  final element = parent.getElement(name);
  return element?.innerText;
}

/// Reads an element's text or `''` when absent.
String readTextOrEmpty(XmlElement parent, String name) => readText(parent, name) ?? '';

/// Reads an element's trimmed, non-empty text or `null`.
String? readTextTrim(XmlElement parent, String name) {
  final value = readText(parent, name)?.trim();
  return (value == null || value.isEmpty) ? null : value;
}
