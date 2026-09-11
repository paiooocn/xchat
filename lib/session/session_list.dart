import 'dart:io';

import 'package:path/path.dart' as p;

import 'session_io.dart';

class SessionListItem {
  final String id;
  final DateTime updated;
  final DateTime created;
  final String sandbox;
  final String? providerId;
  final String? modelId;
  final int totalInput;
  final int totalOutput;
  final int totalCache;
  final String title;
  final String? projectId;
  final List<String> tags;
  SessionListItem({
    required this.id,
    required this.updated,
    required this.created,
    required this.sandbox,
    required this.title,
    this.providerId,
    this.modelId,
    this.totalInput = 0,
    this.totalOutput = 0,
    this.totalCache = 0,
    this.projectId,
    List<String>? tags,
  }) : tags = tags ?? <String>[];
}

class SessionList {
  /// [query] 全文搜索;[tag] 单 tag 过滤;[projectId] 项目过滤。
  /// 任一为空则跳过该过滤。tag 命中 = 包含该 tag(子集匹配)。
  static Future<List<SessionListItem>> list({String? query, String? tag, String? projectId}) async {
    final all = await _loadAll();
    Iterable<SessionListItem> it = all;
    if (tag != null && tag.trim().isNotEmpty) {
      final t = tag.trim();
      it = it.where((x) => x.tags.contains(t));
    }
    if (projectId != null && projectId.isNotEmpty) {
      it = it.where((x) => x.projectId == projectId);
    }
    if (query != null && query.trim().isNotEmpty) {
      final q = query.toLowerCase();
      it = it.where((x) => x.title.toLowerCase().contains(q));
    }
    final out = it.toList();
    out.sort((a, b) => b.updated.compareTo(a.updated));
    return out;
  }

  /// 全文搜索(扫所有 message CDATA)
  static Future<List<SessionListItem>> search(String query, {String? tag, String? projectId}) async {
    if (query.trim().isEmpty) return list(tag: tag, projectId: projectId);
    final q = query.toLowerCase();
    final all = await _loadAll();
    final items = <SessionListItem>[];
    for (final it in all) {
      // 命中条件:任一消息文本含 q
      bool hit = false;
      // 需要拿到 messages,_loadAll 没存 message;这里 lazy 读一次
      // 优化:把全文命中折到 _loadAll 里会更省 IO,但目前简单方案 OK
      final s = await SessionIo.read(it.id);
      for (final m in s.messages) {
        if (m.text.toLowerCase().contains(q)) {
          hit = true;
          break;
        }
      }
      if (!hit) continue;
      if (tag != null && tag.trim().isNotEmpty && !it.tags.contains(tag.trim())) continue;
      if (projectId != null && projectId.isNotEmpty && it.projectId != projectId) continue;
      items.add(it);
    }
    items.sort((a, b) => b.updated.compareTo(a.updated));
    return items;
  }

  /// 一次性把列表信息加载完(不读消息文本)
  static Future<List<SessionListItem>> _loadAll() async {
    final dir = await SessionIo.sessionsDir();
    final entries = await dir
        .list()
        .where((e) => e is File && e.path.endsWith('.xml'))
        .toList();
    final items = <SessionListItem>[];
    for (final e in entries) {
      final id = p.basenameWithoutExtension(e.path);
      try {
        final s = await SessionIo.read(id);
        items.add(SessionListItem(
          id: s.id,
          updated: s.updated,
          created: s.created,
          sandbox: s.sandbox,
          title: s.title ?? s.firstUserText(),
          providerId: s.meta.providerId,
          modelId: s.meta.modelId,
          totalInput: s.sysInput,
          totalOutput: s.sysOutput,
          totalCache: s.sysCache,
          projectId: s.projectId,
          tags: s.tags,
        ));
      } catch (_) {}
    }
    return items;
  }

  static Future<void> delete(String id) async {
    final dir = await SessionIo.sessionsDir();
    final f = File(p.join(dir.path, '$id.xml'));
    if (await f.exists()) await f.delete();
  }
}
