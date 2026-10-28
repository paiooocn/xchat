import 'package:flutter_test/flutter_test.dart';
import 'package:xchat/core/memory_protocol.dart';
import 'package:xchat/core/prompt_utils.dart';

/// The project memory protocol: the injected block must be self-contained,
/// and the skeleton must cover the six index files.
void main() {
  group('memoryProtocolBlock', () {
    test('carries the stable marker (idempotency key)', () {
      expect(memoryProtocolBlock(), startsWith(kMemoryProtocolMarker));
      expect(memoryProtocolBlock(projectName: 'P1'),
          startsWith(kMemoryProtocolMarker));
    });

    test('states where the index lives and what to read', () {
      final block = memoryProtocolBlock();
      expect(block, contains('.memory/'));
      expect(block, contains('README.md'));
      expect(block, contains('STATE.md'));
      expect(block, contains('ARCHITECTURE.md'));
      expect(block, contains('GOTCHAS.md'));
      expect(block, contains('MAP.yaml'));
    });

    test('mentions the maintenance rules and the red lines', () {
      final block = memoryProtocolBlock();
      expect(block, contains('收尾时'));
      expect(block, contains('不写行号'));
      expect(block, contains('以源码为准'));
    });

    test('states the tool prerequisite', () {
      final block = memoryProtocolBlock();
      expect(block, contains('read_file'));
      expect(block, contains('write_file'));
    });

    test('reads STATE.md first and README.md on demand', () {
      final block = memoryProtocolBlock();
      expect(block.indexOf('STATE.md'), lessThan(block.indexOf('README.md')));
    });

    test('names the project when one is given', () {
      expect(memoryProtocolBlock(projectName: '我的项目'), contains('我的项目'));
      expect(memoryProtocolBlock(), isNot(contains('「」')));
    });
  });

  group('memorySkeletonTemplates', () {
    test('covers the six index files', () {
      final templates = memorySkeletonTemplates(projectName: 'P1');
      expect(templates.keys.toSet(), kMemoryFileNames.toSet());
      for (final entry in templates.entries) {
        expect(entry.value.trim(), isNotEmpty, reason: entry.key);
      }
    });

    test('the README carries the start protocol and the rules', () {
      final readme = memorySkeletonTemplates()['README.md']!;
      expect(readme, contains('启动协议'));
      expect(readme, contains('维护规则'));
      expect(readme, contains('不写行号'));
    });

    test('the README names the project', () {
      expect(memorySkeletonTemplates(projectName: '我的项目')['README.md']!,
          contains('我的项目'));
    });

    test('the PROMPT file quotes the same block that gets injected', () {
      final prompt = memorySkeletonTemplates()['PROMPT.md']!;
      expect(prompt, contains(memoryProtocolBlock()));
    });
  });

  group('injectMemoryProtocol', () {
    test('appends the block as a separate section', () {
      final prompt = injectMemoryProtocol('会话提示词');
      expect(prompt, startsWith('会话提示词'));
      expect(prompt, contains(kPromptSectionSeparator));
      expect(prompt, contains('.memory/'));
    });

    test('is idempotent: injecting twice keeps a single block', () {
      final once = injectMemoryProtocol('会话提示词');
      final twice = injectMemoryProtocol(once);
      expect(twice, once);
      expect(
        kMemoryProtocolMarker.allMatches(twice).length,
        1,
        reason: '协议块只能出现一次（压缩会话会带着已注入的提示词再来一次）',
      );
    });

    test('puts a pointer right after the workspace-root line', () {
      final prompt = injectMemoryProtocol(
        injectWorkspaceRoot('会话提示词', '/tmp/sandbox'),
      );
      final lines = prompt.split('\n');
      expect(lines.first, startsWith('工作空间根目录:'));
      expect(lines[1], contains('.memory/'));
      expect(lines[1], contains('STATE.md'));
      // 完整职责仍在末尾。
      expect(prompt, contains(kMemoryProtocolMarker));
    });

    test('a prompt without a workspace-root line gets no pointer', () {
      final prompt = injectMemoryProtocol('会话提示词');
      final lines = prompt.split('\n');
      expect(lines.first, '会话提示词');
    });

    test('an empty prompt yields the block alone', () {
      expect(injectMemoryProtocol(''), memoryProtocolBlock());
      expect(injectMemoryProtocol('   '), memoryProtocolBlock());
    });

    test('keeps the workspace-root line on top', () {
      final prompt = injectMemoryProtocol(
        injectWorkspaceRoot('会话提示词', '/tmp/sandbox'),
      );
      expect(prompt, startsWith('工作空间根目录: /tmp/sandbox'));
      expect(prompt, contains('会话提示词'));
      expect(prompt, contains('.memory/'));
    });
  });
}
