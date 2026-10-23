import 'package:flutter/material.dart';

/// XChat 品牌标记：一个圆角方块里的「X」字形。
///
/// 两种形态：
/// * [BrandMark.solid] —— 侧边栏 / 头像用的实心徽标。
/// * [BrandMark.outline] —— 欢迎页背景上的大号水印（仅描边、低透明度）。
class BrandMark extends StatelessWidget {
  const BrandMark.solid({super.key, this.size = 28})
      : outline = false,
        color = null;

  const BrandMark.outline({super.key, this.size = 240, this.color})
      : outline = true;

  final double size;

  /// Whether only the strokes are painted (no filled badge behind).
  final bool outline;

  /// Stroke color of the outline variant; the solid variant uses white.
  final Color? color;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: size,
      height: size,
      child: CustomPaint(
        painter: outline
            ? _BrandOutlinePainter(color ?? Theme.of(context).colorScheme.outlineVariant)
            : const _BrandSolidPainter(),
      ),
    );
  }
}

/// 实心徽标：圆角渐变底 + 白色「X」。
class _BrandSolidPainter extends CustomPainter {
  const _BrandSolidPainter();

  @override
  void paint(Canvas canvas, Size size) {
    final rect = Offset.zero & size;
    final radius = Radius.circular(size.width * 0.28);
    final bg = Paint()
      ..shader = const LinearGradient(
        begin: Alignment.topLeft,
        end: Alignment.bottomRight,
        colors: [Color(0xFF6E7BFF), Color(0xFF9B5BFF)],
      ).createShader(rect);
    canvas.drawRRect(RRect.fromRectAndRadius(rect, radius), bg);

    final stroke = Paint()
      ..color = Colors.white
      ..style = PaintingStyle.stroke
      ..strokeWidth = size.width * 0.11
      ..strokeCap = StrokeCap.round;
    final w = size.width;
    final h = size.height;
    final path = Path()
      ..moveTo(w * 0.30, h * 0.30)
      ..lineTo(w * 0.70, h * 0.70)
      ..moveTo(w * 0.70, h * 0.30)
      ..lineTo(w * 0.30, h * 0.70);
    canvas.drawPath(path, stroke);
  }

  @override
  bool shouldRepaint(covariant _BrandSolidPainter oldDelegate) => false;
}

/// 描边水印：只有「X」的两笔，线条更细。
class _BrandOutlinePainter extends CustomPainter {
  const _BrandOutlinePainter(this.color);

  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    final stroke = Paint()
      ..color = color
      ..style = PaintingStyle.stroke
      ..strokeWidth = size.width * 0.055
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round;
    final w = size.width;
    final h = size.height;
    final path = Path()
      ..moveTo(w * 0.26, h * 0.26)
      ..lineTo(w * 0.74, h * 0.74)
      ..moveTo(w * 0.74, h * 0.26)
      ..lineTo(w * 0.26, h * 0.74);
    canvas.drawPath(path, stroke);
  }

  @override
  bool shouldRepaint(covariant _BrandOutlinePainter oldDelegate) =>
      oldDelegate.color != color;
}
