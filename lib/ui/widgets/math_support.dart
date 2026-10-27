/// Math (KaTeX/TeX) support for the markdown renderer.
///
/// Recognises the delimiters LLMs actually emit — `$…$`, `$$…$$`, `\(…\)`,
/// `\[…\]` and their multi-line forms — and renders them with
/// `flutter_math_fork` (KaTeX layout engine, fonts bundled, no network).
///
/// The engine implements a KaTeX subset: `align`/`equation` environments,
/// `\tag{}`, `\label{}`, physics shorthands and locally defined macros are all
/// valid KaTeX but rejected by it, so [normalizeTex] rewrites those before
/// rendering. Anything still unsupported degrades to the TeX source instead of
/// an error, see `_TexView`.
library;

import 'package:flutter/material.dart';
import 'package:flutter_math_fork/flutter_math.dart';
import 'package:markdown/markdown.dart' as m;
import 'package:markdown_widget/markdown_widget.dart';

import '../theme/app_fonts.dart';

/// Tag of an inline formula (`$…$`, `\(…\)`).
const String mathInlineTag = 'math-inline';

/// Tag of a display formula (`$$…$$`, `\[…\]`).
const String mathBlockTag = 'math-block';

/// Inline formulas. Order matters: `$$…$$` / `\[…\]` are matched before `$…$`.
final List<m.InlineSyntax> mathInlineSyntaxes = <m.InlineSyntax>[
  _InlineMathSyntax(r'\$\$(.+?)\$\$', block: true),
  _InlineMathSyntax(r'\\\[(.+?)\\\]', block: true),
  _InlineMathSyntax(r'\\\((.+?)\\\)'),
  // `$…$`: no whitespace right after the opening (or before the closing)
  // delimiter, so prices like `$5 ` are far less likely to be swallowed.
  _InlineMathSyntax(r'\$(?!\s)([^$\n]*?[^$\s])\$'),
];

/// Formulas that own their line: `$$ … $$` and `\[ … \]` fences.
final List<m.BlockSyntax> mathBlockSyntaxes = <m.BlockSyntax>[
  _MathBlockSyntax(RegExp(r'^\s*\$\$(.*)$'), r'$$'),
  _MathBlockSyntax(RegExp(r'^\s*\\\[(.*)$'), r'\]'),
];

/// Span generators that turn the nodes produced by the syntaxes above into
/// widgets.
final List<SpanNodeGeneratorWithTag> mathSpanGenerators = <SpanNodeGeneratorWithTag>[
  SpanNodeGeneratorWithTag(
    tag: mathInlineTag,
    generator: (e, config, visitor) => _MathNode(e, display: false),
  ),
  SpanNodeGeneratorWithTag(
    tag: mathBlockTag,
    generator: (e, config, visitor) => _MathNode(e, display: true),
  ),
];

/// Style of the invisible text run that keeps the TeX source copyable.
const TextStyle _copySourceStyle = TextStyle(
  fontSize: 0.01,
  height: 0.01,
  color: Color(0x00000000),
);

/// Formulas render one step larger than the surrounding text: KaTeX glyphs are
/// drawn on a smaller em box than the CJK body font, so at the same nominal
/// size math looks cramped and small.
const double _inlineScale = 1.25;

/// Display formulas sit on their own line, so they get a second step.
const double _displayScale = 1.4;

/// `$12.5, 3` and friends are money, not formulas.
final RegExp _currency = RegExp(r'^[\d\s.,]+$');

/// A `{…}` group with one level of nesting — enough for bodies such as
/// `\mathbb{R}` or `\vec{v}`.
const String _bracedBody = r'\{((?:[^{}]|\{[^{}]*\})*)\}';

/// Environments the engine does not know, mapped to one it does. An empty
/// replacement means "the environment is pure scaffolding, drop it".
const Map<String, String> _environments = <String, String>{
  'align': 'aligned',
  'align*': 'aligned',
  'split': 'aligned',
  'eqnarray': 'aligned',
  'eqnarray*': 'aligned',
  'multline': 'aligned',
  'multline*': 'aligned',
  'flalign': 'aligned',
  'flalign*': 'aligned',
  'gather': 'aligned',
  'gather*': 'aligned',
  'equation': '',
  'equation*': '',
  'displaymath': '',
  'math': '',
};

/// Rewrites KaTeX-valid constructs the bundled engine rejects.
String normalizeTex(String input) {
  var tex = input;

  // align/equation/gather … -> aligned, or nothing at all.
  tex = tex.replaceAllMapped(RegExp(r'\\(begin|end)\{([A-Za-z*]+)\}'), (match) {
    final target = _environments[match[2]];
    if (target == null) return match[0]!;
    return target.isEmpty ? '' : '\\${match[1]}{$target}';
  });

  // Equation numbering/labels only make sense inside a document.
  tex = tex.replaceAll(RegExp(r'\\(?:tag|label)\*?\s*' + _bracedBody), '');
  tex = tex.replaceAll(RegExp(r'\\(?:nonumber|notag)(?![A-Za-z])'), '');

  // `physics` package shorthands.
  tex = tex.replaceAll(RegExp(r'\\(?:qty|pqty|bqty|Bqty|vqty)\*?(?![A-Za-z])'), '');
  tex = _applyToGroup(tex, 'abs', (arg) => r'\left|' + arg + r'\right|');
  tex = _applyToGroup(tex, 'norm', (arg) => r'\left\|' + arg + r'\right\|');

  return _expandMacros(tex).trim();
}

/// Replaces `\command{arg}` with `build(arg)`.
String _applyToGroup(String tex, String command, String Function(String) build) {
  final pattern = RegExp(r'\\' + command + r'\s*' + _bracedBody);
  return tex.replaceAllMapped(pattern, (match) => build(match[1]!));
}

/// Inlines `\newcommand` / `\def` / `\DeclareMathOperator` definitions and
/// expands their uses — the engine has no macro support and would otherwise
/// fail on the first `\name`.
String _expandMacros(String tex) {
  final macros = <String, String>{};

  // \DeclareMathOperator{\Tr}{Tr} -> \Tr expands to \operatorname{Tr}.
  final declared = _consumeDefinitions(
    tex,
    RegExp(r'\\DeclareMathOperator\*?\s*\{\\([A-Za-z]+)\}\s*' + _bracedBody),
    nameGroups: const <int>[1],
    bodyGroup: 2,
    build: (name, body) => '\\operatorname{$body}',
  );
  tex = declared.$1;
  macros.addAll(declared.$2);

  // \newcommand{\R}{\mathbb{R}} / \def\R{...}
  final defined = _consumeDefinitions(
    tex,
    RegExp(
      r'\\(?:newcommand|renewcommand|providecommand|def)\*?\s*'
      r'(?:\{\\([A-Za-z]+)\}|\\([A-Za-z]+))\s*(?:\[\d+\])?\s*'
      r'\{((?:[^{}]|\{[^{}]*\})*)\}',
    ),
    nameGroups: const <int>[1, 2],
    bodyGroup: 3,
    build: (name, body) => body,
  );
  tex = defined.$1;
  macros.addAll(defined.$2);

  // Bounded expansion so macros may reference each other.
  for (var pass = 0; pass < 3; pass++) {
    for (final entry in macros.entries) {
      tex = tex.replaceAll(
        RegExp(RegExp.escape(entry.key) + r'(?![A-Za-z])'),
        entry.value,
      );
    }
  }
  return tex;
}

/// Strips every match of [definition] (macro name + body), returning the
/// remaining text and the `\name -> replacement` pairs it defined.
(String, Map<String, String>) _consumeDefinitions(
  String tex,
  RegExp definition, {
  required List<int> nameGroups,
  required int bodyGroup,
  required String Function(String name, String body) build,
}) {
  final macros = <String, String>{};
  var out = tex;
  var from = 0;
  while (from < out.length) {
    final match = definition.firstMatch(out.substring(from));
    if (match == null) break;
    final name = nameGroups
        .map((group) => match.group(group))
        .firstWhere((value) => value != null, orElse: () => null);
    if (name == null) break;
    macros['\\$name'] = build(name, match.group(bodyGroup) ?? '');
    final start = from + match.start;
    out = out.replaceRange(start, from + match.end, '');
    from = start;
  }
  return (out, macros);
}

class _InlineMathSyntax extends m.InlineSyntax {
  _InlineMathSyntax(super.pattern, {this.block = false});

  /// The matched span is a display formula (e.g. `$$x$$` inside a sentence).
  final bool block;

  @override
  bool onMatch(m.InlineParser parser, Match match) {
    final tex = match[1]!.trim();
    if (tex.isEmpty || (!block && _currency.hasMatch(tex))) {
      // Not math: emit the delimiter run verbatim instead of consuming it.
      parser.addNode(m.Text(match[0]!));
      return true;
    }
    parser.addNode(m.Element.text(block ? mathBlockTag : mathInlineTag, tex));
    return true;
  }
}

class _MathBlockSyntax extends m.BlockSyntax {
  const _MathBlockSyntax(this.pattern, this.closer);

  @override
  final RegExp pattern;

  /// Delimiter that ends the block, e.g. `$$` or `\]`.
  final String closer;

  @override
  m.Node? parse(m.BlockParser parser) {
    final buffer = StringBuffer();
    var line = (pattern.firstMatch(parser.current.content)?.group(1) ?? '').trim();
    parser.advance();
    while (true) {
      final close = line.indexOf(closer);
      if (close >= 0) {
        buffer.write(line.substring(0, close));
        break;
      }
      buffer.writeln(line);
      if (parser.isDone) break;
      line = parser.current.content;
      parser.advance();
    }
    return m.Element.text(mathBlockTag, buffer.toString().trim());
  }
}

/// Renders one formula as a `WidgetSpan`.
///
/// A `WidgetSpan` contributes no plain text, so a copied selection would lose
/// the formula entirely. An invisible, sub-pixel text run carrying the TeX
/// source is appended for exactly that reason.
class _MathNode extends ElementNode {
  _MathNode(this.element, {required this.display});

  final dynamic element;
  final bool display;

  String get tex => (element.textContent as String).trim();

  @override
  InlineSpan build() {
    final source = display ? '\$\$$tex\$\$' : '\$$tex\$';
    return TextSpan(
      children: [
        WidgetSpan(
          alignment: PlaceholderAlignment.middle,
          child: _TexView(tex: tex, display: display),
        ),
        TextSpan(text: source, style: _copySourceStyle),
      ],
    );
  }
}

/// The formula itself: inline formulas stay in the text flow, display formulas
/// are centred and scroll horizontally when too wide for the bubble.
class _TexView extends StatelessWidget {
  const _TexView({required this.tex, required this.display});

  final String tex;
  final bool display;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    var style = DefaultTextStyle.of(context).style;
    style = style.copyWith(
      fontSize: style.fontSize ?? theme.textTheme.bodyMedium?.fontSize ?? 16,
      color: style.color ?? theme.colorScheme.onSurface,
    );
    // KaTeX glyphs are drawn on a smaller em box than the CJK body text, so both
    // kinds of formulas are rendered one step larger than the surrounding text.
    final fontSize = style.fontSize! * (display ? _displayScale : _inlineScale);
    final math = Math.tex(
      normalizeTex(tex),
      mathStyle: display ? MathStyle.display : MathStyle.text,
      textStyle: style.copyWith(fontSize: fontSize),
      // Unsupported TeX must never break the message: fall back to the source,
      // which stays readable and copyable.
      onErrorFallback: (error) => Text(
        '\$$tex\$',
        style: style.copyWith(fontFamily: AppFonts.mono),
      ),
    );
    // An inline formula can be wider than a narrow bubble or a table cell; the
    // math renderer cannot wrap, so shrink it to fit instead of letting the
    // paragraph paint an overflow.
    if (!display) {
      return FittedBox(
        fit: BoxFit.scaleDown,
        alignment: Alignment.centerLeft,
        child: math,
      );
    }
    // A display formula gets the whole line, centred, and scrolls sideways when
    // wider than the bubble. Both widgets support dry layout, which the table
    // and intrinsic-width passes require — unlike `LayoutBuilder`.
    return Center(
      child: SingleChildScrollView(scrollDirection: Axis.horizontal, child: math),
    );
  }
}
