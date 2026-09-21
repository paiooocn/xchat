import 'package:flutter/material.dart';
import 'package:markdown_widget/markdown_widget.dart';

import '../theme/app_fonts.dart';

/// Renders assistant/user markdown as a non-scrolling column.
Widget markdownView(String data, {Color? codeBackground}) {
  if (data.trim().isEmpty) return const SizedBox.shrink();
  return MarkdownBlock(
    data: data,
    selectable: true,
    config: MarkdownConfig(
      configs: [
        // Force the bundled monospace font for fenced code blocks on every
        // platform (markdown_widget otherwise falls back to a system font).
        PreConfig(
          textStyle: const TextStyle(
            fontFamily: AppFonts.mono,
            fontFamilyFallback: AppFonts.monoFallback,
          ),
        ),
      ],
    ),
    generator: MarkdownGenerator(
      generators: [
        // Replace the built-in `pre` node: markdown_widget's CodeBlockNode
        // dereferences `attributes['class']!` for every fence without a
        // language, logging "get language error:Null check operator used on a
        // null value". This node reads the language defensively instead.
        SpanNodeGeneratorWithTag(
          tag: MarkdownTag.pre.name,
          generator: (e, config, visitor) =>
              _SafeCodeBlockNode(e, config.pre, visitor, codeBackground),
        ),
      ],
    ),
  );
}

class _SafeCodeBlockNode extends ElementNode {
  _SafeCodeBlockNode(this.element, this.preConfig, this.visitor, this.background);

  final dynamic element;
  final PreConfig preConfig;
  final WidgetVisitor visitor;
  final Color? background;

  @override
  InlineSpan build() {
    final content = element.textContent as String;
    final language = _languageOf(element);
    final lines = content
        .trim()
        .split(visitor.splitRegExp ?? WidgetVisitor.defaultSplitRegExp);
    if (lines.isNotEmpty && lines.last.isEmpty) lines.removeLast();
    final decoration = preConfig.decoration;
    final baseColor =
        background ?? (decoration is BoxDecoration ? decoration.color : null);
    final widget = Container(
      width: double.infinity,
      margin: preConfig.margin,
      padding: preConfig.padding,
      decoration: BoxDecoration(
        color: baseColor,
        borderRadius: BorderRadius.circular(6),
      ),
      child: SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            for (final line in lines)
              ProxyRichText(
                TextSpan(
                  children: highLightSpans(
                    line,
                    language: language,
                    theme: preConfig.theme,
                    textStyle: style,
                    styleNotMatched: preConfig.styleNotMatched,
                  ),
                ),
                richTextBuilder: visitor.richTextBuilder,
              ),
          ],
        ),
      ),
    );
    return WidgetSpan(child: widget);
  }

  /// Extracts the fence language (e.g. `language-dart` -> `dart`), falling back
  /// to plaintext, without throwing when the info string is absent.
  String _languageOf(dynamic element) {
    try {
      final children = element.children as List?;
      final first = (children != null && children.isNotEmpty) ? children.first : null;
      final attrs = first?.attributes as Map?;
      final cls = attrs?['class'] as String?;
      if (cls == null || cls.isEmpty) return 'plaintext';
      return cls.contains('-') ? cls.split('-').last : cls;
    } catch (_) {
      return 'plaintext';
    }
  }

  @override
  TextStyle get style => preConfig.textStyle.merge(parentStyle);
}
