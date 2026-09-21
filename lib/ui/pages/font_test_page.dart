import 'package:flutter/material.dart';

import '../theme/app_fonts.dart';

/// Shows the cross-platform font rendering check panel as a dialog.
Future<void> showFontTestDialog(BuildContext context) {
  return showDialog<void>(
    context: context,
    builder: (context) => AlertDialog(
      title: const Text('字体显示测试'),
      content: SizedBox(
        width: 640,
        height: 560,
        child: const FontTestPanel(),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('关闭'),
        ),
      ],
    ),
  );
}

/// Scrollable panel exercising every font aspect we care about, so output can
/// be compared across Android / iOS / macOS / Windows / Linux.
class FontTestPanel extends StatelessWidget {
  const FontTestPanel({super.key});

  @override
  Widget build(BuildContext context) {
    return ListView(
      shrinkWrap: true,
      padding: EdgeInsets.zero,
      children: [
        const _FontSourceProbe(),
        _sectionStyle('字重 / Weight', [
          const _Line('Regular 400 · 常规：敏捷的棕色狐狸 ABCdef 123', FontWeight.w400),
          const _Line('Bold 700 · 加粗：敏捷的棕色狐狸 ABCdef 123', FontWeight.w700),
          const _Line('Medium 500 · 中等（未打包，引擎取最近字重）', FontWeight.w500),
        ]),
        _sectionStyle('字号阶梯 / Size scale', [
          for (final s in const [12.0, 14.0, 16.0, 20.0, 24.0, 32.0])
            Text(
              '${s.toInt()}px — XChat 跨平台 LLM Agent 字体渲染',
              style: TextStyle(fontSize: s, height: 1.4),
            ),
        ]),
        _sectionText('中英混排 / Mixed CJK + Latin', _mixed),
        _sectionText('中文标点 / Punctuation', _punctuation),
        _sectionText('数字与符号 / Digits & symbols', _symbols),
        _sectionText('全角 / 半角', _fullHalf),
        _sectionText('生僻字 · 扩展A / Rare & Ext-A', _rare),
        _sectionText('等宽代码 / Monospace', _code, mono: true),
        _sectionText('Emoji 回退 / Emoji fallback', _emoji),
      ],
    );
  }

  Widget _sectionStyle(String title, List<Widget> lines) => Padding(
        padding: const EdgeInsets.only(bottom: 20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [_Title(title), const Divider(height: 12), ...lines],
        ),
      );

  Widget _sectionText(String title, String body, {bool mono = false}) =>
      Padding(
        padding: const EdgeInsets.only(bottom: 20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _Title(title),
            const Divider(height: 12),
            SelectableText(
              body,
              style: mono
                  ? const TextStyle(
                      fontFamily: AppFonts.mono,
                      fontFamilyFallback: AppFonts.monoFallback,
                      height: 1.5,
                    )
                  : const TextStyle(height: 1.5),
            ),
          ],
        ),
      );
}

class _Line extends StatelessWidget {
  const _Line(this.text, this.weight);

  final String text;
  final FontWeight weight;

  @override
  Widget build(BuildContext context) => Text(
        text,
        style: TextStyle(fontSize: 20, fontWeight: weight, height: 1.6),
      );
}

class _Title extends StatelessWidget {
  const _Title(this.text);
  final String text;

  @override
  Widget build(BuildContext context) => Text(
        text,
        style: Theme.of(context).textTheme.titleSmall?.copyWith(
              fontWeight: FontWeight.bold,
              color: Theme.of(context).colorScheme.primary,
            ),
      );
}

/// Objective check: measures the same string with the bundled family vs. the
/// engine/platform default. If the widths differ, the bundled font is active
/// and independent of the system font.
class _FontSourceProbe extends StatelessWidget {
  const _FontSourceProbe();

  static const String _sample = '敏捷的棕色狐狸 ABCdef 123';

  double _width(TextStyle? style) {
    final tp = TextPainter(
      text: TextSpan(text: _sample, style: style),
      textDirection: TextDirection.ltr,
    )..layout();
    return tp.width;
  }

  @override
  Widget build(BuildContext context) {
    // A bogus family forces the engine's fallback path, giving the true
    // platform-default metrics for reference.
    final bundled = _width(const TextStyle(fontFamily: AppFonts.sans, fontSize: 16));
    final platformDefault = _width(const TextStyle(fontSize: 16));
    final monoWidth = _width(const TextStyle(fontFamily: AppFonts.mono, fontSize: 16));

    // JetBrains Mono is bundled and matches no system font, so a width that
    // differs from the platform default proves the manifest families loaded.
    final monoLoaded = (monoWidth - platformDefault).abs() > 0.5;
    final sansSameAsSystem = (bundled - platformDefault).abs() <= 0.5;

    return Padding(
      padding: const EdgeInsets.only(bottom: 20),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const _Title('字体来源比对 / Source check'),
          const Divider(height: 12),
          Text('sans  = ${AppFonts.sans}'),
          Text('mono  = ${AppFonts.mono}'),
          const SizedBox(height: 6),
          SelectableText(
            '打包 sans 宽度: ${bundled.toStringAsFixed(1)}\n'
            '系统默认宽度  : ${platformDefault.toStringAsFixed(1)}\n'
            '打包 mono 宽度: ${monoWidth.toStringAsFixed(1)}',
          ),
          const SizedBox(height: 6),
          Text(
            monoLoaded
                ? '✅ 打包字体已加载（JetBrainsMono 与系统不同 → manifest 字体已注册）'
                : '⚠️ 打包字体可能未加载',
            style: TextStyle(
              color: monoLoaded ? Colors.green : Colors.red,
              fontWeight: FontWeight.bold,
            ),
          ),
          const SizedBox(height: 4),
          Text(
            sansSameAsSystem
                ? 'ℹ️ sans 宽度与系统默认一致：本机装有同源字体（如 Noto Sans CJK SC）'
                : 'ℹ️ sans 宽度与系统默认不同：渲染用的是打包字体',
            style: const TextStyle(color: Colors.blueGrey),
          ),
        ],
      ),
    );
  }
}

const String _mixed =
    'The quick brown fox 敏捷的棕色狐狸\n'
    'Flutter 引擎渲染，跨平台一致：Android、iOS、macOS、Windows、Linux。\n'
    '混合 ABCdef123 与 中文汉字，检查基线与字距是否对齐。';

const String _punctuation =
    '逗号，句号。顿号、分号；冒号：\n'
    '感叹！问号？引号“双引号”‘单引号’\n'
    '破折号——省略号……书名号《书名》【方括号】\n'
    '圆括号（内容）〔着重〕〈尖括号〉';

const String _symbols =
    '0123456789  + - * / = < > %  ¥ \$ € @ # & ~ ^ |\n'
    '↑ ↓ ← → ↔  ①②③  ⅓ ½ ¼  ⒈';

const String _fullHalf =
    '全角：ＡＢＣ１２３，。！？\n'
    '半角：ABC123,.!?';

const String _rare =
    '扩展A：㐀 㐁 㐂 㐃 㐄 㐅\n'
    '生僻：龘 靐 齉 㸚 䶮 犇 鑫 淼 焱 垚';

const String _code =
    'class XChatAgent {\n'
    '  final String model = "gpt-4o";\n'
    '  Future<void> run(String prompt) async {\n'
    '    // 中文注释也走等宽字体\n'
    '    print(">>> \$prompt");\n'
    '  }\n'
    '}';

const String _emoji = '😀 🚀 ✅ ❌ ⭐ 🎉 🔧 📦 👨‍💻 🀄';
