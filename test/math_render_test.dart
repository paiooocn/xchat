import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_math_fork/flutter_math.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:xchat/ui/widgets/markdown_view.dart';
import 'package:xchat/ui/widgets/math_support.dart';

/// TeX an assistant realistically writes; the engine must render all of it
/// (directly or after [normalizeTex]) instead of showing a parse error.
const _commonTex = <String>[
  r'\frac{a}{b}',
  r'\vec{v}\cdot\vec{a}',
  r'\int_0^1 x^2\,dx',
  r'\sum_{i=1}^n i',
  r'\begin{aligned}a&=b\\c&=d\end{aligned}',
  r'\begin{align}a&=b\end{align}',
  r'\begin{equation}x=1\end{equation}',
  r'\begin{gather}x=1\\y=2\end{gather}',
  r'\begin{split}a&=b\end{split}',
  r'E=mc^2\tag{1}',
  r'E=mc^2\label{eq:energy}',
  r'\begin{aligned}a&=b\nonumber\end{aligned}',
  r'\qty(\frac{a}{b})',
  r'\abs{x}',
  r'\norm{v}',
  r'\newcommand{\R}{\mathbb{R}}\R^n',
  r'\def\v{\vec{v}}\v',
  r'\DeclareMathOperator{\Tr}{Tr}\Tr A',
  r'\text{当 } t=0',
  r'\begin{cases}1&x>0\\0&x\le0\end{cases}',
  r'\begin{bmatrix}1&2\\3&4\end{bmatrix}',
  r'\operatorname{argmax}_x f(x)',
  r'\left\{x\middle|x>0\right\}',
];

const _md = r'''
行内公式 $E=mc^2$ 结束

块级公式：

$$
\int_0^1 x^2 dx
$$

价格 $5 和 $10 不是公式
''';

Future<void> _pump(WidgetTester tester, String markdown) => tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SizedBox(width: 500, child: markdownView(markdown)),
        ),
      ),
    );

String _allText(WidgetTester tester) => find
    .byType(RichText)
    .evaluate()
    .map((e) => (e.widget as RichText).text.toPlainText())
    .join('|');

void main() {
  // Regression: a real message reported as "KaTeX 解析报错". Inline `$$…$$` in
  // the middle of a paragraph, `\vec`, `\frac` and bare `$a$` must all survive.
  const physics = r'''
在中学阶段，我们习惯把牛顿第二定律写成$$F = ma$$但这里有一个隐含的跳跃：中学里的 $a$ 通常被当作一个已知的具体数值；而在真实的力学问题中，$a$ 往往依赖于时间、位置、速度，我们并不知道它。于是自然的推广是：把 $a$ 写成对时间的导数，把 $\vec F$ 写成 $\vec r, \vec v, t$ 的函数，于是牛顿第二定律变成了一个关于未知函数的微分方程。$$m\frac{d\vec v}{dt} = \vec F(\vec r, \vec v, t)$$这就是质点动力学的微分方程模型。求解它，就等于"求运动"。
''';

  testWidgets('the reported physics message renders every formula', (tester) async {
    await _pump(tester, physics);
    expect(tester.takeException(), isNull);
    // 2 display + 5 inline (`$a$` ×3, `$\vec F$`, `$\vec r, \vec v, t$`).
    expect(find.byType(Math), findsNWidgets(7));
    final text = _allText(tester);
    expect(text, isNot(contains('Parse Error')));
    // Copying still yields the TeX source of both display formulas.
    expect(text, contains(r'$$F = ma$$'));
    expect(
      text,
      contains(r'$$m\frac{d\vec v}{dt} = \vec F(\vec r, \vec v, t)$$'),
    );
  });

  test('common assistant TeX renders without a parse error', () {
    final failed = <String>[];
    for (final tex in _commonTex) {
      final math = Math.tex(
        normalizeTex(tex),
        mathStyle: MathStyle.text,
        textStyle: const TextStyle(fontSize: 16, color: Color(0xFF000000)),
      );
      if (math.parseError != null) failed.add('$tex -> ${math.parseError!.message}');
    }
    expect(failed, isEmpty);
  });

  testWidgets('the reported lesson renders without parse or layout errors', (tester) async {
    // Full markdown of the message that was reported as "KaTeX 解析报错": two
    // tables whose cells hold `\hat`, `\sqrt` and `\left|…\right|`, plus ~80
    // inline and 20+ display formulas.
    final md = File('test/fixtures/reported_newton.md').readAsStringSync();
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SingleChildScrollView(
            child: SizedBox(width: 760, child: markdownView(md)),
          ),
        ),
      ),
    );
    expect(tester.takeException(), isNull);
    final maths = find.byType(Math).evaluate().map((e) => e.widget as Math);
    expect(maths.length, greaterThan(100));
    expect(maths.where((math) => math.parseError != null), isEmpty);
    expect(find.textContaining('Parse Error', findRichText: true), findsNothing);
  });

  testWidgets('inline and block formulas are rendered as math', (tester) async {
    await _pump(tester, _md);
    expect(tester.takeException(), isNull);
    // One inline (`$E=mc^2$`) + one display (`$$\int…$$`).
    expect(find.byType(Math), findsNWidgets(2));
    // The TeX source stays copyable even though it is drawn as a widget.
    final text = _allText(tester);
    expect(text, contains(r'$E=mc^2$'));
    expect(text, contains(r'\int_0^1 x^2 dx'));
  });

  testWidgets('prices are not treated as formulas', (tester) async {
    await _pump(tester, r'价格 $5 和 $10 不是公式');
    expect(find.byType(Math), findsNothing);
    expect(find.textContaining(r'$5', findRichText: true), findsWidgets);
  });

  testWidgets('a broken formula falls back instead of throwing', (tester) async {
    await _pump(tester, r'坏公式 $\frac{1}{$ 也要能显示');
    expect(tester.takeException(), isNull);
    // The parser rejects it, so the raw source is shown.
    expect(find.textContaining(r'\frac', findRichText: true), findsWidgets);
  });
}
