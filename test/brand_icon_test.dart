import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:xchat/ui/widgets/brand_mark.dart';

/// Renders the sidebar brand mark (侧边栏左上角的图标) into the launcher-icon
/// masters used by the platform icon configurations.
///
/// This is a generator, not an assertion: it only runs when
/// `XCHAT_GEN_ICONS=1` is set, so the normal test run stays green.
///
/// Regenerate with:
///   bash tool/gen_icons.sh
void main() {
  final generate = Platform.environment['XCHAT_GEN_ICONS'] == '1';
  testWidgets('brand mark masters（仅 XCHAT_GEN_ICONS=1 时运行）', (tester) async {
    for (final size in <int>[1024, 512, 256]) {
      tester.view.physicalSize = Size(size.toDouble(), size.toDouble());
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final key = ValueKey('brand_$size');
      await tester.pumpWidget(
        MaterialApp(
          debugShowCheckedModeBanner: false,
          home: Scaffold(
            backgroundColor: Colors.transparent,
            body: Center(
              child: RepaintBoundary(
                key: key,
                child: BrandMark.solid(size: size.toDouble()),
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      await expectLater(
        find.byKey(key),
        matchesGoldenFile('../tool/icons/brand_$size.png'),
      );
    }
  }, skip: !generate);
}
