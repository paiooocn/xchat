import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:xchat/ui/widgets/markdown_view.dart';

void main() {
  testWidgets('copying a rendered message keeps its line breaks', (tester) async {
    String? copied;
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      SystemChannels.platform,
      (call) async {
        if (call.method == 'Clipboard.setData') {
          copied = (call.arguments as Map)['text'] as String?;
        }
        return null;
      },
    );
    addTearDown(
      () => tester.binding.defaultBinaryMessenger
          .setMockMethodCallHandler(SystemChannels.platform, null),
    );

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Align(
            alignment: Alignment.topLeft,
            child: SizedBox(
              width: 400,
              child: markdownView(
                'first paragraph\n\n'
                'second paragraph\n\n'
                '- item one\n'
                '- item two\n\n'
                '```dart\n'
                'var a = 1;\n'
                'var b = 2;\n'
                '```',
              ),
            ),
          ),
        ),
      ),
    );

    // Drag-select everything the way a user would.
    final region = find.byType(SelectionArea);
    final gesture = await tester.startGesture(
      tester.getTopLeft(region) + const Offset(4, 2),
      kind: PointerDeviceKind.mouse,
    );
    await tester.pump(const Duration(milliseconds: 20));
    await gesture.moveTo(tester.getTopLeft(region) + const Offset(60, 5));
    await tester.pump();
    await gesture.moveTo(
      tester.getBottomRight(region) + const Offset(60, 40),
      timeStamp: const Duration(milliseconds: 200),
    );
    await tester.pump();
    await gesture.up();
    await tester.pump(const Duration(milliseconds: 200));

    final area = tester.state<SelectionAreaState>(region);
    area.selectableRegion.contextMenuButtonItems
        .firstWhere((item) => item.type == ContextMenuButtonType.copy)
        .onPressed!();
    await tester.pump();

    // Paragraphs, list items and code lines are separate rendered widgets, but
    // the clipboard should still hold the line breaks.
    expect(copied, isNotNull);
    expect(copied, contains('first paragraph\nsecond paragraph'));
    expect(copied, contains('item one\nitem two'));
    expect(copied, contains('var a = 1;\nvar b = 2;'));
  });
}
