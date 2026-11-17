import 'project.dart';
import 'session.dart';

/// 侧栏搜索框的三种语义（会话 Tab）：
///
/// * `文本`  → 搜**项目**（名称 / 说明）
/// * `$文本` → 搜**全局会话**（标题）
/// * `#文本` → 搜**标签**（项目 + 会话）
///
/// 解析与匹配都是纯函数，方便单测；UI 只负责把结果分组渲染。
enum SidebarSearchMode { project, globalSession, tag }

class SidebarSearch {
  const SidebarSearch({required this.mode, required this.text});

  final SidebarSearchMode mode;

  /// 去掉前缀后的关键字（已 trim）。
  final String text;

  /// 空查询 = 不过滤。
  bool get isEmpty => text.isEmpty;
}

/// 解析搜索框输入。前缀后允许空格（`# 标签` 等价 `#标签`）。
SidebarSearch parseSidebarSearch(String raw) {
  final text = raw.trim();
  if (text.isEmpty) {
    return const SidebarSearch(mode: SidebarSearchMode.project, text: '');
  }
  if (text.startsWith('#')) {
    return SidebarSearch(
      mode: SidebarSearchMode.tag,
      text: text.substring(1).trim(),
    );
  }
  if (text.startsWith(r'$')) {
    return SidebarSearch(
      mode: SidebarSearchMode.globalSession,
      text: text.substring(1).trim(),
    );
  }
  return SidebarSearch(mode: SidebarSearchMode.project, text: text);
}

bool _contains(String haystack, String needle) =>
    haystack.toLowerCase().contains(needle.toLowerCase());

/// 项目是否命中当前搜索（项目模式按名称/说明；标签模式按标签）。
bool projectMatchesSearch(Project project, SidebarSearch search) {
  switch (search.mode) {
    case SidebarSearchMode.project:
      return _contains(project.name, search.text) ||
          _contains(project.description, search.text);
    case SidebarSearchMode.globalSession:
      return false;
    case SidebarSearchMode.tag:
      return matchesTagQuery(project.tags, search.text);
  }
}

/// 会话是否命中当前搜索（全局会话模式要求无项目且标题命中；标签模式按标签）。
bool sessionMatchesSearch(Session session, SidebarSearch search) {
  switch (search.mode) {
    case SidebarSearchMode.project:
      return false;
    case SidebarSearchMode.globalSession:
      return session.projectId.isEmpty &&
          _contains(session.title, search.text);
    case SidebarSearchMode.tag:
      return matchesTagQuery(session.tags, search.text);
  }
}

/// 已选中的标签 chips 是否命中（大小写敏感，与既有筛选行为一致）。
bool matchesTagFilter(List<String> tags, Set<String> selected) =>
    selected.isEmpty || tags.any(selected.contains);

/// `#关键字` 是否命中标签（大小写不敏感，子串匹配）。
bool matchesTagQuery(List<String> tags, String query) {
  if (query.isEmpty) return true;
  final needle = query.toLowerCase();
  return tags.any((tag) => tag.toLowerCase().contains(needle));
}
