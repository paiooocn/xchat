import 'package:flutter_test/flutter_test.dart';
import 'package:xchat/core/prompt_utils.dart';

void main() {
  group('injectWorkspaceRoot', () {
    test('prepends the workspace-root line, separated by a blank line', () {
      expect(
        injectWorkspaceRoot('你是一个助手。', '/abs/work'),
        '工作空间根目录: /abs/work\n\n你是一个助手。',
      );
    });

    test('an empty prompt becomes the single workspace-root line', () {
      expect(injectWorkspaceRoot('', '/abs/work'), '工作空间根目录: /abs/work');
    });

    test('replaces a hand-written placeholder line instead of duplicating', () {
      expect(
        injectWorkspaceRoot('工作空间根目录: {sandbox}\n你是一个助手。', '/abs/work'),
        '工作空间根目录: /abs/work\n\n你是一个助手。',
      );
    });

    test('moves a mid-prompt workspace-root line to the top (expanded)', () {
      expect(
        injectWorkspaceRoot('正文\n工作空间根目录: /old/path\n更多正文', '/abs/work'),
        '工作空间根目录: /abs/work\n\n正文\n更多正文',
      );
    });

    test('drops every workspace-root line, keeping exactly one', () {
      expect(
        injectWorkspaceRoot(
          '工作空间根目录: {sandbox}\n正文\n工作空间根目录: /old/path',
          '/abs/work',
        ),
        '工作空间根目录: /abs/work\n\n正文',
      );
    });

    test('preserves the body verbatim', () {
      expect(
        injectWorkspaceRoot('第一行\n\n  缩进行  \n', '/abs/work'),
        '工作空间根目录: /abs/work\n\n第一行\n\n  缩进行',
      );
    });

    test('does not stack blank lines when the body starts with one', () {
      expect(
        injectWorkspaceRoot('\n正文', '/abs/work'),
        '工作空间根目录: /abs/work\n\n正文',
      );
    });
  });
}
