import 'package:flutter_test/flutter_test.dart';
import 'package:xchat/core/prompt_utils.dart';
import 'package:xchat/data/xml/project_xml.dart';
import 'package:xchat/models/catalog_index.dart';
import 'package:xchat/models/project.dart';

void main() {
  group('composePromptSections', () {
    test('joins 会话提示词 / 项目提示词 / 新增提示词 with a --- separator', () {
      expect(
        composePromptSections(<String>['会话', '项目', '新增']),
        '会话\n---\n项目\n---\n新增',
      );
    });

    test('drops empty sections instead of leaving stray separators', () {
      expect(
        composePromptSections(<String>['会话', '', '新增']),
        '会话\n---\n新增',
      );
      expect(
        composePromptSections(<String>['', '项目', '']),
        '项目',
      );
      expect(composePromptSections(<String>['', '', '']), '');
    });

    test('trims each section', () {
      expect(
        composePromptSections(<String>['  会话  ', '\n项目\n', ' 新增 ']),
        '会话\n---\n项目\n---\n新增',
      );
    });
  });

  group('ProjectXml', () {
    Project project({String prompt = ''}) => Project(
          id: 'p1',
          name: '项目一',
          description: '说明',
          sandbox: '/tmp/xchat/projects/p1',
          createdAt: DateTime.utc(2025),
          updatedAt: DateTime.utc(2025),
          systemPrompt: prompt,
        );

    test('round-trips the project prompt', () {
      const prompt = '项目级提示词：只关心 src/ 目录';
      final xml = ProjectXml.encode(project(prompt: prompt));
      expect(xml.contains('<system_prompt>'), isTrue);

      final decoded = ProjectXml.decode(xml, filePath: '/tmp/xchat/projects/p1.xml');
      expect(decoded.systemPrompt, prompt);
    });

    test('an absent prompt decodes as empty', () {
      final decoded = ProjectXml.decode(
        ProjectXml.encode(project()),
        filePath: '/tmp/xchat/projects/p1.xml',
      );
      expect(decoded.systemPrompt, isEmpty);
    });

    test('keeps a multi-line prompt verbatim (CDATA)', () {
      const prompt = '第一行\n第二行 <标签>';
      final decoded = ProjectXml.decode(
        ProjectXml.encode(project(prompt: prompt)),
        filePath: '/tmp/xchat/projects/p1.xml',
      );
      expect(decoded.systemPrompt, prompt);
    });
  });

  group('ProjectIndexEntry', () {
    test('carries the project prompt through the catalog index', () {
      final entry = ProjectIndexEntry.fromProject(
        Project(
          id: 'p1',
          name: '项目一',
          sandbox: '/tmp/xchat/projects/p1',
          createdAt: DateTime.utc(2025),
          updatedAt: DateTime.utc(2025),
          systemPrompt: '项目提示词',
        ),
      );
      expect(entry.toJson()['system_prompt'], '项目提示词');
      expect(entry.toProject().systemPrompt, '项目提示词');

      final restored = ProjectIndexEntry.fromJson(entry.toJson());
      expect(restored.systemPrompt, '项目提示词');
      expect(restored.toProject().systemPrompt, '项目提示词');
    });

    test('an index written before project prompts existed loads empty', () {
      final restored = ProjectIndexEntry.fromJson(<String, Object?>{
        'id': 'p1',
        'sandbox': '/tmp/xchat/projects/p1',
      });
      expect(restored.systemPrompt, isEmpty);
    });
  });
}
