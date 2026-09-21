import 'package:flutter/material.dart';
import 'package:markdown_widget/markdown_widget.dart';

import '../theme/app_fonts.dart';

// Code palette shared by inline `code` spans and fenced code blocks so they
// stay visually consistent in both brightness modes.
const _codeMono = TextStyle(
  fontFamily: AppFonts.mono,
  fontFamilyFallback: AppFonts.monoFallback,
);
const _codeBgDark = Color(0xCC3A3F4B);
const _codeBgLight = Color(0xCCeff1f3);
const _codeFgDark = Color(0xFFE6E6E6);
const _codeFgLight = Color(0xFF24292F);

/// Renders assistant/user markdown as a non-scrolling column.
Widget markdownView(String data, {Color? codeBackground}) {
  if (data.trim().isEmpty) return const SizedBox.shrink();
  return Builder(
    builder: (context) {
      final dark = Theme.of(context).brightness == Brightness.dark;
      // Fenced code blocks: reuse markdown_widget's dark preset (dark syntax
      // theme) in dark mode, otherwise the default light preset. Only the
      // bundled monospace font and the background are overridden.
      final preConfig = (dark ? PreConfig.darkConfig : const PreConfig()).copy(
        textStyle: _codeMono,
        decoration: BoxDecoration(
          color: dark ? _codeBgDark : _codeBgLight,
          borderRadius: BorderRadius.circular(6),
        ),
      );
      return MarkdownBlock(
        data: data,
        selectable: true,
        config: MarkdownConfig(
          configs: [
            preConfig,
            // Inline `code` spans. markdown_widget's default background is a
            // light grey, which leaves dark-mode text (light) invisible.
            CodeConfig(
              style: _codeMono.copyWith(
                backgroundColor: dark ? _codeBgDark : _codeBgLight,
                color: dark ? _codeFgDark : _codeFgLight,
              ),
            ),
            // Block quotes (`>`). The default text color is a dark grey that is
            // unreadable on the dark surface (and vanishes under the selection
            // highlight), so use the light-on-dark palette in dark mode.
            dark ? BlockquoteConfig.darkConfig : const BlockquoteConfig(),
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
            // Render `>` block quotes in italic. BlockquoteConfig has no font
            // style knob, so subclass the node and tweak its inherited style.
            SpanNodeGeneratorWithTag(
              tag: MarkdownTag.blockquote.name,
              generator: (e, config, visitor) =>
                  _ItalicBlockquoteNode(config.blockquote, visitor),
            ),
          ],
        ),
      );
    },
  );
}

/// Like [BlockquoteNode], but forces italic text for `>` block quotes.
class _ItalicBlockquoteNode extends BlockquoteNode {
  _ItalicBlockquoteNode(super.config, super.visitor);

  @override
  TextStyle? get style {
    final base = super.style;
    return base == null
        ? const TextStyle(fontStyle: FontStyle.italic)
        : base.copyWith(fontStyle: FontStyle.italic);
  }
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
  TextStyle get style {
    // Drop the inherited color: it would otherwise override the syntax theme
    // (and, in dark mode, paint the app's light body color on the light code
    // background). Plain code text then inherits the ambient text color, which
    // already matches the background brightness.
    final merged = preConfig.textStyle.merge(parentStyle);
    return TextStyle(
      inherit: merged.inherit,
      fontFamily: merged.fontFamily,
      fontFamilyFallback: merged.fontFamilyFallback,
      fontSize: merged.fontSize,
      fontWeight: merged.fontWeight,
      fontStyle: merged.fontStyle,
      letterSpacing: merged.letterSpacing,
      wordSpacing: merged.wordSpacing,
      height: merged.height,
      decoration: merged.decoration,
    );
  }
}
