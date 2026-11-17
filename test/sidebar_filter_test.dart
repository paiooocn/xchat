import 'package:flutter_test/flutter_test.dart';
import 'package:xchat/models/project.dart';
import 'package:xchat/models/session.dart';
import 'package:xchat/models/sidebar_filter.dart';

Project _project({
  String name = '',
  String description = '',
  List<String> tags = const <String>[],
}) =>
    Project(
      id: 'p1',
      name: name,
      description: description,
      sandbox: '/tmp/p1',
      createdAt: DateTime.utc(2025),
      updatedAt: DateTime.utc(2025),
      tags: tags,
    );

Session _session({
  String title = '',
  String projectId = '',
  List<String> tags = const <String>[],
}) =>
    Session(
      id: 's1',
      title: title,
      projectId: projectId,
      tags: tags,
      sandbox: '/tmp/s1',
      createdAt: DateTime.utc(2025),
      updatedAt: DateTime.utc(2025),
    );

void main() {
  group('parseSidebarSearch', () {
    test('空查询保持 project 模式且为空', () {
      final q = parseSidebarSearch('   ');
      expect(q.isEmpty, isTrue);
      expect(q.mode, SidebarSearchMode.project);
    });

    test('纯文本 = 搜项目', () {
      final q = parseSidebarSearch('  Alpha  ');
      expect(q.mode, SidebarSearchMode.project);
      expect(q.text, 'Alpha');
    });

    test(r'$文本 = 搜全局会话', () {
      final q = parseSidebarSearch(r'$Global');
      expect(q.mode, SidebarSearchMode.globalSession);
      expect(q.text, 'Global');
    });

    test('#文本 = 搜标签', () {
      final q = parseSidebarSearch('#工作');
      expect(q.mode, SidebarSearchMode.tag);
      expect(q.text, '工作');
    });

    test('前缀后允许空格', () {
      expect(parseSidebarSearch('# 工作').text, '工作');
      expect(parseSidebarSearch(r'$ 全局').text, '全局');
    });
  });

  group('匹配', () {
    final project = _project(name: 'Alpha', description: '第一个', tags: ['t-a']);
    final other = _project(name: 'Beta', tags: ['t-b']);
    final global = _session(title: 'GlobalOne', tags: ['t-g']);
    final inner = _session(title: 'Inner', projectId: 'p1', tags: ['t-i']);

    test('项目模式：名称 / 说明子串命中', () {
      const q = SidebarSearch(mode: SidebarSearchMode.project, text: 'alp');
      expect(projectMatchesSearch(project, q), isTrue);
      expect(projectMatchesSearch(other, q), isFalse);

      const desc = SidebarSearch(mode: SidebarSearchMode.project, text: '第一个');
      expect(projectMatchesSearch(project, desc), isTrue);
    });

    test('项目模式：会话一律不命中', () {
      const q = SidebarSearch(mode: SidebarSearchMode.project, text: 'global');
      expect(sessionMatchesSearch(global, q), isFalse);
      expect(sessionMatchesSearch(inner, q), isFalse);
    });

    test('全局会话模式：只命中无项目且标题命中的会话', () {
      const q = SidebarSearch(mode: SidebarSearchMode.globalSession, text: 'global');
      expect(sessionMatchesSearch(global, q), isTrue);
      expect(sessionMatchesSearch(inner, q), isFalse);
      expect(projectMatchesSearch(project, q), isFalse);
    });

    test('标签模式：大小写不敏感的子串匹配', () {
      const q = SidebarSearch(mode: SidebarSearchMode.tag, text: 'T-A');
      expect(projectMatchesSearch(project, q), isTrue);
      expect(projectMatchesSearch(other, q), isFalse);
      expect(sessionMatchesSearch(inner, q), isFalse);
      expect(sessionMatchesSearch(global, q), isFalse);
    });

    test('matchesTagFilter：选中标签取交集', () {
      expect(matchesTagFilter(project.tags, {'t-a'}), isTrue);
      expect(matchesTagFilter(project.tags, {'t-b'}), isFalse);
      expect(matchesTagFilter(project.tags, <String>{}), isTrue);
    });
  });
}
