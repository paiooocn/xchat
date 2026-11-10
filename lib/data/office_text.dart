import 'dart:convert';
import 'dart:io' as io;

import 'package:archive/archive.dart';
import 'package:xml/xml.dart';

// Plain-text extraction for the OOXML formats a user is most likely to drag
// onto a chat: Word (.docx), Excel (.xlsx) and PowerPoint (.pptx).
//
// All three are ZIP containers of XML, so no native dependency is needed — the
// text is pulled out with `archive` + `xml` and then handed to the model as an
// ordinary text attachment. Legacy binary formats (.doc / .xls / .ppt) and .pdf
// are NOT supported: they need a real parser.

/// Extensions we can extract text from.
const Set<String> kOfficeExtensions = {'.docx', '.xlsx', '.pptx'};

/// A hard cap on the container itself: an office file is a zip, so this is
/// about memory during extraction, not about tokens (the extracted text is
/// capped separately, by `kMaxTextAttachmentChars`).
const int kMaxOfficeFileBytes = 32 * 1024 * 1024;

/// Whether [extension] (with dot, lower case) is an extractable office format.
bool isOfficeExtension(String extension) => kOfficeExtensions.contains(extension);

/// Extracts the readable text of an office document, or `null` when the file is
/// not an office format, is corrupt, or holds no text at all.
///
/// Never throws: a broken archive or an unexpected layout degrades to `null`,
/// which the intake then reports as an unsupported file.
Future<String?> extractOfficeText(String path, {int maxChars = 200 * 1000}) async {
  try {
    final length = await io.File(path).length();
    if (length <= 0 || length > kMaxOfficeFileBytes) return null;
    final archive = ZipDecoder().decodeBytes(await io.File(path).readAsBytes());
    final text = switch (extensionOf(path)) {
      '.docx' => _docxText(archive),
      '.xlsx' => _xlsxText(archive),
      '.pptx' => _pptxText(archive),
      _ => null,
    };
    if (text == null) return null;
    final trimmed = text.trim();
    if (trimmed.isEmpty) return null;
    return trimmed.length > maxChars
        ? '${trimmed.substring(0, maxChars)}\n…（内容过长，已截断）'
        : trimmed;
  } catch (_) {
    return null;
  }
}

/// Lower-cased extension of [path], with the dot (`''` when there is none).
String extensionOf(String path) {
  final dot = path.lastIndexOf('.');
  final slash = path.lastIndexOf(RegExp(r'[/\\]'));
  return dot <= slash ? '' : path.substring(dot).toLowerCase();
}

String? _docxText(Archive archive) {
  final document = _readXml(archive, 'word/document.xml');
  if (document == null) return null;
  final out = StringBuffer();
  _walkWord(document.rootElement, out);
  return out.toString();
}

void _walkWord(XmlNode node, StringBuffer out) {
  for (final child in node.children) {
    if (child is! XmlElement) continue;
    switch (child.name.local) {
      case 't':
        out.write(child.innerText);
      case 'tab':
        out.write('\t');
      case 'br':
        out.write('\n');
      case 'tr':
        for (final cell in _childrenNamed(child, 'tc')) {
          _walkWord(cell, out);
          out.write('\t');
        }
        out.write('\n');
      case 'p':
        _walkWord(child, out);
        out.write('\n');
      case 'rPr': // run formatting — no text in here
      case 'pPr':
        break;
      default:
        _walkWord(child, out);
    }
  }
}

String? _xlsxText(Archive archive) {
  final shared = <String>[];
  final sharedXml = _readXml(archive, 'xl/sharedStrings.xml');
  if (sharedXml != null) {
    for (final item in _childrenNamed(sharedXml.rootElement, 'si')) {
      shared.add(_allText(item));
    }
  }
  final names = _sheetNames(archive);
  final sheets = _numberedEntries(archive, 'xl/worksheets/sheet', '.xml');
  if (sheets.isEmpty) return null;
  final out = StringBuffer();
  for (var i = 0; i < sheets.length; i++) {
    final xml = _parse(sheets[i].content);
    if (xml == null) continue;
    final label =
        i < names.length && names[i].isNotEmpty ? names[i] : 'Sheet${i + 1}';
    out.writeln('--- 工作表：$label ---');
    // Rows live inside `<sheetData>`, not directly under `<worksheet>`.
    for (final row in _descendantsNamed(xml.rootElement, 'row')) {
      final cells = <String>[];
      for (final cell in _childrenNamed(row, 'c')) {
        cells.add(switch (cell.getAttribute('t')) {
          's' => _sharedValue(shared, _firstInner(cell, 'v')),
          'inlineStr' => _allText(_firstElement(cell, 'is') ?? cell),
          _ => _firstInner(cell, 'v'),
        });
      }
      while (cells.isNotEmpty && cells.last.isEmpty) {
        cells.removeLast();
      }
      if (cells.isNotEmpty) out.writeln(cells.join('\t'));
    }
  }
  return out.toString();
}

String? _pptxText(Archive archive) {
  final slides = _numberedEntries(archive, 'ppt/slides/slide', '.xml');
  if (slides.isEmpty) return null;
  final out = StringBuffer();
  for (var i = 0; i < slides.length; i++) {
    final xml = _parse(slides[i].content);
    if (xml == null) continue;
    out.writeln('--- 幻灯片 ${i + 1} ---');
    for (final paragraph in _descendantsNamed(xml.rootElement, 'p')) {
      final text = _allText(paragraph).trim();
      if (text.isNotEmpty) out.writeln(text);
    }
  }
  return out.toString();
}

String _sharedValue(List<String> shared, String index) {
  final parsed = int.tryParse(index);
  if (parsed == null || parsed < 0 || parsed >= shared.length) return '';
  return shared[parsed];
}

/// `<w:t>` / `<a:t>` texts inside [element], in document order.
String _allText(XmlElement element) {
  final out = StringBuffer();
  for (final node in element.descendants.whereType<XmlElement>()) {
    if (node.name.local == 't') out.write(node.innerText);
  }
  return out.toString();
}

XmlElement? _firstElement(XmlElement element, String name) {
  for (final child in _childrenNamed(element, name)) {
    return child;
  }
  return null;
}

/// Direct children whose **local** name is [name] — OOXML parts are namespace
/// prefixed (`w:tc`, `a:p`) in Word/PowerPoint but bare in Excel, and
/// `findElements('tc')` compares the qualified name, i.e. misses both cases.
Iterable<XmlElement> _childrenNamed(XmlElement element, String name) =>
    element.childElements.where((child) => child.name.local == name);

Iterable<XmlElement> _descendantsNamed(XmlElement element, String name) =>
    element.descendants.whereType<XmlElement>().where((e) => e.name.local == name);

String _firstInner(XmlElement element, String name) =>
    _firstElement(element, name)?.innerText.trim() ?? '';

List<String> _sheetNames(Archive archive) {
  final xml = _readXml(archive, 'xl/workbook.xml');
  if (xml == null) return const [];
  return [
    for (final sheet in _descendantsNamed(xml.rootElement, 'sheet'))
      sheet.getAttribute('name') ?? '',
  ];
}

/// Worksheet / slide entries in numeric order (`slide2` before `slide10`).
List<ArchiveFile> _numberedEntries(Archive archive, String prefix, String suffix) {
  final matched = <(int, ArchiveFile)>[];
  for (final file in archive.files) {
    if (!file.name.startsWith(prefix) || !file.name.endsWith(suffix)) continue;
    final middle =
        file.name.substring(prefix.length, file.name.length - suffix.length);
    final index = int.tryParse(middle);
    if (index != null) matched.add((index, file));
  }
  matched.sort((a, b) => a.$1.compareTo(b.$1));
  return [for (final entry in matched) entry.$2];
}

XmlDocument? _readXml(Archive archive, String name) {
  for (final file in archive.files) {
    if (file.name == name) return _parse(file.content);
  }
  return null;
}

XmlDocument? _parse(List<int> bytes) {
  try {
    return XmlDocument.parse(utf8.decode(bytes, allowMalformed: true));
  } catch (_) {
    return null;
  }
}
