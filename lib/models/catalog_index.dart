import '../core/json_utils.dart';
import 'agent_mode.dart';
import 'project.dart';
import 'session.dart';
import 'session_message.dart';
import 'session_params.dart';

/// Lightweight, message-free projection of a [Session] stored in the catalog
/// index. Reading the index avoids parsing every session XML just to render the
/// list; a session's messages are only loaded when it is actually opened.
class SessionIndexEntry {
  SessionIndexEntry({
    required this.id,
    required this.sandbox,
    required this.createdAt,
    required this.updatedAt,
    this.toolCalls = 0,
    this.toolCallsLimit = 0,
    this.title = '',
    this.projectId = '',
    this.archivedAt,
    List<String>? tags,
    this.provider = '',
    this.model = '',
    this.mode = AgentMode.auto,
    this.kind = SessionKind.normal,
    this.taskCount = 0,
    this.taskDoneCount = 0,
    this.thinkingReplyMode = ThinkingReplyMode.auto,
    this.webSearchEnabled = true,
    List<String>? tools,
    SessionParams? params,
  })  : tags = tags ?? <String>[],
        tools = tools ?? <String>[],
        params = params ?? SessionParams();

  String id;
  String sandbox;
  DateTime createdAt;
  DateTime updatedAt;
  int toolCalls;
  int toolCallsLimit;
  String title;
  String projectId;
  DateTime? archivedAt;
  List<String> tags;
  String provider;
  String model;
  AgentMode mode;

  /// Session presentation mode ([SessionKind]); task titles/messages are not
  /// in the index — they come from the session XML when it is opened.
  SessionKind kind;

  /// Number of task items (0 for a normal session).
  int taskCount;

  /// Number of task items marked done.
  int taskDoneCount;

  ThinkingReplyMode thinkingReplyMode;
  bool webSearchEnabled;
  List<String> tools;
  SessionParams params;

  bool get archived => archivedAt != null;

  factory SessionIndexEntry.fromSession(Session session) => SessionIndexEntry(
        id: session.id,
        sandbox: session.sandbox,
        createdAt: session.createdAt,
        updatedAt: session.updatedAt,
        toolCalls: session.toolCalls,
        toolCallsLimit: session.toolCallsLimit,
        title: session.title,
        projectId: session.projectId,
        archivedAt: session.archivedAt,
        tags: List<String>.of(session.tags),
        provider: session.provider,
        model: session.model,
        mode: session.mode,
        kind: session.kind,
        taskCount: session.tasks.length,
        taskDoneCount: session.tasks.where((t) => t.done).length,
        thinkingReplyMode: session.thinkingReplyMode,
        webSearchEnabled: session.webSearchEnabled,
        tools: List<String>.of(session.tools),
        params: session.params.copyWith(),
      );

  factory SessionIndexEntry.fromJson(Object? value) {
    final json = asMap(value);
    return SessionIndexEntry(
      id: asString(json['id']) ?? '',
      sandbox: asString(json['sandbox']) ?? '',
      createdAt: DateTime.tryParse(asString(json['created_at']) ?? '') ?? DateTime.now(),
      updatedAt: DateTime.tryParse(asString(json['updated_at']) ?? '') ?? DateTime.now(),
      toolCalls: asInt(json['tool_calls']) ?? 0,
      toolCallsLimit: asInt(json['tool_calls_limit']) ?? 0,
      title: asString(json['title']) ?? '',
      projectId: asString(json['project']) ?? '',
      archivedAt: DateTime.tryParse(asString(json['archived_at']) ?? ''),
      tags: asStringList(json['tags']),
      provider: asString(json['provider']) ?? '',
      model: asString(json['model']) ?? '',
      mode: AgentMode.parse(asString(json['mode'])),
      kind: SessionKind.parse(asString(json['kind'])),
      taskCount: asInt(json['task_count']) ?? 0,
      taskDoneCount: asInt(json['task_done_count']) ?? 0,
      thinkingReplyMode: ThinkingReplyMode.parse(asString(json['thinking_reply_mode'])),
      webSearchEnabled: asBool(json['web_search_enabled'], fallback: true),
      tools: asStringList(json['tools']),
      params: SessionParams.fromJson(json['params']),
    );
  }

  Map<String, Object?> toJson() => <String, Object?>{
        'id': id,
        'sandbox': sandbox,
        'created_at': createdAt.toUtc().toIso8601String(),
        'updated_at': updatedAt.toUtc().toIso8601String(),
        'tool_calls': toolCalls,
        'tool_calls_limit': toolCallsLimit,
        'title': title,
        if (projectId.isNotEmpty) 'project': projectId,
        if (archivedAt != null) 'archived_at': archivedAt!.toUtc().toIso8601String(),
        if (tags.isNotEmpty) 'tags': tags,
        'provider': provider,
        'model': model,
        'mode': mode.wire,
        'kind': kind.wire,
        if (taskCount > 0) 'task_count': taskCount,
        if (taskDoneCount > 0) 'task_done_count': taskDoneCount,
        'thinking_reply_mode': thinkingReplyMode.wire,
        'web_search_enabled': webSearchEnabled,
        if (tools.isNotEmpty) 'tools': tools,
        'params': params.toJson(),
      };

  /// Rebuilds the (message-less) session this entry describes.
  Session toSession() => Session(
        id: id,
        sandbox: sandbox,
        createdAt: createdAt,
        updatedAt: updatedAt,
        toolCalls: toolCalls,
        toolCallsLimit: toolCallsLimit,
        title: title,
        projectId: projectId,
        archivedAt: archivedAt,
        tags: List<String>.of(tags),
        provider: provider,
        model: model,
        mode: mode,
        kind: kind,
        thinkingReplyMode: thinkingReplyMode,
        webSearchEnabled: webSearchEnabled,
        tools: List<String>.of(tools),
        params: params.copyWith(),
      );
}

/// Lightweight projection of a [Project] stored in the catalog index.
class ProjectIndexEntry {
  ProjectIndexEntry({
    required this.id,
    this.name = '',
    this.description = '',
    required this.sandbox,
    required this.createdAt,
    required this.updatedAt,
    this.provider = '',
    this.model = '',
    this.archivedAt,
    this.systemPrompt = '',
    this.memoryEnabled,
  });

  String id;
  String name;
  String description;
  String sandbox;
  DateTime createdAt;
  DateTime updatedAt;
  String provider;
  String model;
  DateTime? archivedAt;

  /// The project's system prompt (kept in the index so the session wizard can
  /// offer it without re-reading every project file).
  String systemPrompt;

  /// Whether the project carries a `.memory/` memory index.
  ///
  /// `null` = the project predates the flag (never set) — see `Project`.
  bool? memoryEnabled;

  bool get archived => archivedAt != null;

  factory ProjectIndexEntry.fromProject(Project project) => ProjectIndexEntry(
        id: project.id,
        name: project.name,
        description: project.description,
        sandbox: project.sandbox,
        createdAt: project.createdAt,
        updatedAt: project.updatedAt,
        provider: project.provider,
        model: project.model,
        archivedAt: project.archivedAt,
        systemPrompt: project.systemPrompt,
        memoryEnabled: project.memoryEnabled,
      );

  factory ProjectIndexEntry.fromJson(Object? value) {
    final json = asMap(value);
    return ProjectIndexEntry(
      id: asString(json['id']) ?? '',
      name: asString(json['name']) ?? '',
      description: asString(json['description']) ?? '',
      sandbox: asString(json['sandbox']) ?? '',
      createdAt: DateTime.tryParse(asString(json['created_at']) ?? '') ?? DateTime.now(),
      updatedAt: DateTime.tryParse(asString(json['updated_at']) ?? '') ?? DateTime.now(),
      provider: asString(json['provider']) ?? '',
      model: asString(json['model']) ?? '',
      archivedAt: DateTime.tryParse(asString(json['archived_at']) ?? ''),
      systemPrompt: asString(json['system_prompt']) ?? '',
      memoryEnabled: json.containsKey('memory_enabled')
          ? asBool(json['memory_enabled'], fallback: false)
          : null,
    );
  }

  Map<String, Object?> toJson() => <String, Object?>{
        'id': id,
        'name': name,
        'description': description,
        'sandbox': sandbox,
        'created_at': createdAt.toUtc().toIso8601String(),
        'updated_at': updatedAt.toUtc().toIso8601String(),
        'provider': provider,
        'model': model,
        'system_prompt': systemPrompt,
        if (memoryEnabled != null) 'memory_enabled': memoryEnabled,
        if (archivedAt != null) 'archived_at': archivedAt!.toUtc().toIso8601String(),
      };

  Project toProject() => Project(
        id: id,
        name: name,
        description: description,
        sandbox: sandbox,
        createdAt: createdAt,
        updatedAt: updatedAt,
        provider: provider,
        model: model,
        archivedAt: archivedAt,
        systemPrompt: systemPrompt,
        memoryEnabled: memoryEnabled,
      );
}

/// The on-disk catalog: active/archived sessions and projects, kept in four
/// indexed buckets to make listing and archive lookups cheap.
class CatalogIndex {
  CatalogIndex({
    List<SessionIndexEntry>? sessions,
    List<ProjectIndexEntry>? projects,
    List<SessionIndexEntry>? archivedSessions,
    List<ProjectIndexEntry>? archivedProjects,
  })  : sessions = sessions ?? <SessionIndexEntry>[],
        projects = projects ?? <ProjectIndexEntry>[],
        archivedSessions = archivedSessions ?? <SessionIndexEntry>[],
        archivedProjects = archivedProjects ?? <ProjectIndexEntry>[];

  /// Bumped to 2 when project entries gained `system_prompt`: older index
  /// files lack the field, so they are discarded and rebuilt from the project
  /// XML files instead of silently losing every project prompt.
  ///
  /// Bumped to 3 when project entries gained `memory_enabled` — same reason:
  /// an index without the field would silently disable every project's memory
  /// index.
  ///
  /// Bumped to 4 when session entries gained `kind` / task counters — an index
  /// without them would present every task-style session as a normal one (the
  /// task list would never open).
  static const int version = 4;

  List<SessionIndexEntry> sessions;
  List<ProjectIndexEntry> projects;
  List<SessionIndexEntry> archivedSessions;
  List<ProjectIndexEntry> archivedProjects;

  Iterable<String> get allSessionIds sync* {
    for (final e in sessions) {
      yield e.id;
    }
    for (final e in archivedSessions) {
      yield e.id;
    }
  }

  Iterable<String> get allProjectIds sync* {
    for (final e in projects) {
      yield e.id;
    }
    for (final e in archivedProjects) {
      yield e.id;
    }
  }

  Map<String, Object?> toJson() => <String, Object?>{
        'version': version,
        'sessions': sessions.map((e) => e.toJson()).toList(),
        'projects': projects.map((e) => e.toJson()).toList(),
        'archived_sessions': archivedSessions.map((e) => e.toJson()).toList(),
        'archived_projects': archivedProjects.map((e) => e.toJson()).toList(),
      };

  factory CatalogIndex.fromJson(Object? value) {
    final json = asMap(value);
    return CatalogIndex(
      sessions: asList(json['sessions']).map(SessionIndexEntry.fromJson).toList(),
      projects: asList(json['projects']).map(ProjectIndexEntry.fromJson).toList(),
      archivedSessions:
          asList(json['archived_sessions']).map(SessionIndexEntry.fromJson).toList(),
      archivedProjects:
          asList(json['archived_projects']).map(ProjectIndexEntry.fromJson).toList(),
    );
  }
}
