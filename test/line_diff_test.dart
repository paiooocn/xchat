import 'package:flutter_test/flutter_test.dart';
import 'package:xchat/util/line_diff.dart';

List<String> texts(List<DiffLine> lines, DiffLineType type) =>
    lines.where((l) => l.type == type).map((l) => l.text).toList();

void main() {
  group('line diff', () {
    test('空输入', () {
      final lines = diffLines('', '');
      expect(texts(lines, DiffLineType.delete), isEmpty);
      expect(texts(lines, DiffLineType.insert), isEmpty);

      final added = diffLines('', '新的一行');
      expect(texts(added, DiffLineType.insert), <String>['新的一行']);
      expect(texts(added, DiffLineType.delete), isEmpty);

      final removed = diffLines('旧的一行', '');
      expect(texts(removed, DiffLineType.delete), <String>['旧的一行']);
      expect(texts(removed, DiffLineType.insert), isEmpty);
    });

    test('无变化', () {
      final lines = diffLines('一\n二\n三', '一\n二\n三');
      expect(texts(lines, DiffLineType.equal), <String>['一', '二', '三']);
      expect(texts(lines, DiffLineType.delete), isEmpty);
      expect(texts(lines, DiffLineType.insert), isEmpty);
      expect(diffChangeCount(lines), 0);
    });

    test('修改一行', () {
      final lines = diffLines('一\n二\n三', '一\n改过的二\n三');
      expect(texts(lines, DiffLineType.delete), <String>['二']);
      expect(texts(lines, DiffLineType.insert), <String>['改过的二']);
      expect(texts(lines, DiffLineType.equal), <String>['一', '三']);
      expect(diffChangeCount(lines), 2);
    });

    test('新增一行', () {
      final lines = diffLines('一\n三', '一\n二\n三');
      expect(texts(lines, DiffLineType.insert), <String>['二']);
      expect(texts(lines, DiffLineType.delete), isEmpty);
      expect(texts(lines, DiffLineType.equal), <String>['一', '三']);
    });

    test('删除一行', () {
      final lines = diffLines('一\n二\n三', '一\n三');
      expect(texts(lines, DiffLineType.delete), <String>['二']);
      expect(texts(lines, DiffLineType.insert), isEmpty);
    });

    test('首尾相同、中间整段替换', () {
      final lines = diffLines('头\n旧1\n旧2\n尾', '头\n新1\n尾');
      expect(texts(lines, DiffLineType.equal), containsAll(<String>['头', '尾']));
      expect(texts(lines, DiffLineType.delete), containsAll(<String>['旧1', '旧2']));
      expect(texts(lines, DiffLineType.insert), contains('新1'));
    });

    test('行的顺序：结果按原文顺序铺开', () {
      final lines = diffLines('a\nb\nc', 'a\nB\nc');
      final kinds = lines.map((l) => l.type).toList();
      expect(kinds, <DiffLineType>[
        DiffLineType.equal,
        DiffLineType.delete,
        DiffLineType.insert,
        DiffLineType.equal,
      ]);
    });
  });
}
