import 'dart:io';

import '../core/app_paths.dart';
import '../models/project.dart';
import '../models/session.dart';
import '../models/session_message.dart';
import '../models/sync_item.dart';
import 'index_repository.dart';
import 'project_repository.dart';
import 'session_repository.dart';
import 'xml/project_xml.dart';
import 'xml/session_xml.dart';

/// File-system side of the LAN sync: builds the manifest from the catalog and
/// moves session/project XML documents in and out.
///
/// Two rules are enforced **here** (not in the UI):
/// * 归档的不可见不同步 — the manifest only carries the active buckets, and an
///   incoming item that is archived is refused even if a peer sends it anyway.
/// * 工作目录不同步 — the peer's `sandbox` never lands on this device: every
///   import re-targets the item at a local working directory (the local
///   project's sandbox for project sessions, `sandboxs/<id>` otherwise) and
///   rewrites the `工作空间根目录:` line inside the system prompt accordingly.
class SyncRepository {
  SyncRepository({
    required this.paths,
    required this.indexRepository,
    required this.sessionRepository,
    required this.projectRepository,
  });

  final AppPaths paths;
  final IndexRepository indexRepository;
  final SessionRepository sessionRepository;
  final ProjectRepository projectRepository;

  /// Lists every syncable item: active projects first, then active sessions
  /// (both newest-updated first). Archived items are **not** part of it.
  ///
  /// The list comes from the catalog index **only**: a file that sits in
  /// `sessions/` / `projects/` without an index entry is *not* syncable — those
  /// leftovers are handled explicitly by 「未索引文件管理」
  /// (`lib/data/orphan_repository.dart`), not silently smuggled through sync.
  Future<List<SyncItemSummary>> manifest() async {
    final index = await indexRepository.load();
    final projectNames = <String, String>{
      for (final project in index.projects) project.id: project.name,
    };
    final sessionCount = <String, int>{};
    for (final session in index.sessions) {
      if (session.projectId.isEmpty) continue;
      sessionCount[session.projectId] = (sessionCount[session.projectId] ?? 0) + 1;
    }

    final projects = <SyncItemSummary>[
      for (final project in index.projects)
        SyncItemSummary(
          kind: SyncItemKind.project,
          id: project.id,
          title: project.name.isEmpty ? '未命名项目' : project.name,
          subtitle: project.description,
          updatedAt: project.updatedAt,
          sessionCount: sessionCount[project.id] ?? 0,
        ),
    ]..sort((a, b) => b.updatedAt.compareTo(a.updatedAt));

    final sessions = <SyncItemSummary>[
      for (final session in index.sessions)
        SyncItemSummary(
          kind: SyncItemKind.session,
          id: session.id,
          title: session.title.isEmpty ? '未命名会话' : session.title,
          subtitle: projectNames[session.projectId] ?? '',
          updatedAt: session.updatedAt,
          projectId: session.projectId,
        ),
    ]..sort((a, b) => b.updatedAt.compareTo(a.updatedAt));

    return <SyncItemSummary>[...projects, ...sessions];
  }

  /// Reads the XML of the items named by [keys] (`<kind>:<id>`).
  Future<List<SyncItemPayload>> exportItems(Iterable<String> keys) async {
    final payloads = <SyncItemPayload>[];
    for (final key in keys) {
      final payload = await _exportOne(key);
      if (payload != null) payloads.add(payload);
    }
    return payloads;
  }

  Future<SyncItemPayload?> _exportOne(String key) async {
    final separator = key.indexOf(':');
    if (separator <= 0) return null;
    final kind = SyncItemKind.parse(key.substring(0, separator));
    final id = key.substring(separator + 1);
    if (id.isEmpty) return null;

    final file = File(kind == SyncItemKind.project
        ? paths.projectFile(id)
        : paths.sessionFile(id));
    if (!await file.exists()) return null;
    final String xml;
    try {
      xml = await file.readAsString();
    } on FileSystemException {
      return null;
    }
    if (kind == SyncItemKind.project) {
      final project = await _readProject(id);
      if (project == null || project.isArchived) return null;
      return SyncItemPayload(
        kind: kind,
        id: id,
        title: project.name,
        updatedAt: project.updatedAt,
        xml: xml,
      );
    }
    final session = await _readSession(id);
    if (session == null || session.isArchived) return null;
    return SyncItemPayload(
      kind: kind,
      id: id,
      title: session.title,
      updatedAt: session.updatedAt,
      xml: xml,
    );
  }

  /// Writes the incoming items (projects first, so their sessions can inherit
  /// the local working directory).
  ///
  /// An existing item is only overwritten when the incoming copy is newer — the
  /// newer side always wins, which makes a run in both directions converge.
  Future<SyncImportOutcome> importItems(List<SyncItemPayload> items) async {
    final outcome = SyncImportOutcome();
    for (final item in items.where((e) => e.kind == SyncItemKind.project)) {
      await _importOne(item, outcome);
    }
    for (final item in items.where((e) => e.kind == SyncItemKind.session)) {
      await _importOne(item, outcome);
    }
    return outcome;
  }

  Future<void> _importOne(SyncItemPayload item, SyncImportOutcome outcome) async {
    final label = item.title.isEmpty ? item.id : item.title;
    try {
      if (item.xml.trim().isEmpty) {
        outcome.skipped.add('$label：内容为空');
        return;
      }
      if (item.kind == SyncItemKind.project) {
        await _importProject(item, label, outcome);
      } else {
        await _importSession(item, label, outcome);
      }
    } catch (error) {
      outcome.skipped.add('$label：$error');
    }
  }

  Future<void> _importProject(
    SyncItemPayload item,
    String label,
    SyncImportOutcome outcome,
  ) async {
    final incoming = ProjectXml.decode(item.xml, filePath: paths.projectFile(item.id));
    if (incoming.isArchived) {
      outcome.skipped.add('$label：已归档，不同步');
      return;
    }
    final existing = await _readProject(item.id);
    if (existing != null && !existing.updatedAt.isBefore(incoming.updatedAt)) {
      outcome.skipped.add('$label：本机版本较新，已跳过');
      return;
    }
    // 工作目录不同步：沿用本机已有的工作目录，否则用本机默认项目目录。
    final peerSandbox = incoming.sandbox;
    final localSandbox =
        existing?.sandbox ?? paths.projectSandboxDir(item.id);
    incoming
      ..sandbox = localSandbox
      ..systemPrompt =
          _retarget(incoming.systemPrompt, peerSandbox, localSandbox);
    incoming.id = item.id;
    await projectRepository.write(incoming);
    outcome.imported++;
    outcome.touchedProjectIds.add(item.id);
  }

  Future<void> _importSession(
    SyncItemPayload item,
    String label,
    SyncImportOutcome outcome,
  ) async {
    final incoming =
        SessionXml.decode(item.xml, filePath: paths.sessionFile(item.id));
    if (incoming.isArchived) {
      outcome.skipped.add('$label：已归档，不同步');
      return;
    }
    final existing = await _readSession(item.id);
    if (existing != null && !existing.updatedAt.isBefore(incoming.updatedAt)) {
      outcome.skipped.add('$label：本机版本较新，已跳过');
      return;
    }
    final peerSandbox = incoming.sandbox;
    final project = incoming.projectId.isEmpty
        ? null
        : await _readProject(incoming.projectId);
    // 工作目录不同步：项目会话用本机项目目录，其余用本机会话目录。
    final localSandbox = project?.sandbox ?? paths.sessionSandboxDir(item.id);
    incoming
      ..id = item.id
      ..sandbox = localSandbox;
    if (incoming.projectId.isNotEmpty && project == null) {
      // The owning project was not synced: keep the session standalone instead
      // of pointing at a project id that does not exist here.
      incoming.projectId = '';
    }
    if (peerSandbox.isNotEmpty && peerSandbox != localSandbox) {
      for (final message in incoming.messages) {
        if (message.role != MessageRole.system) continue;
        final content = message.content;
        if (content == null) continue;
        message.content = _retarget(content, peerSandbox, localSandbox);
      }
    }
    await sessionRepository.write(incoming);
    outcome.imported++;
    outcome.touchedSessionIds.add(item.id);
  }

  /// Replaces the peer's working-directory path with the local one.
  static String _retarget(String text, String from, String to) {
    if (text.isEmpty || from.isEmpty || from == to) return text;
    return text.replaceAll(from, to);
  }

  Future<Project?> _readProject(String id) async {
    if (id.isEmpty) return null;
    try {
      return await projectRepository.read(id);
    } catch (_) {
      return null;
    }
  }

  Future<Session?> _readSession(String id) async {
    if (id.isEmpty) return null;
    try {
      return await sessionRepository.read(id);
    } catch (_) {
      return null;
    }
  }
}
