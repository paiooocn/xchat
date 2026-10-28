import '../core/json_utils.dart';

/// A project groups sessions and provides their default sandbox directory.
///
/// On disk a project is `projects/{id}.xml` and its working directory defaults
/// to `projects/{id}`. Sessions created inside a project inherit that sandbox.
class Project {
  Project({
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

  /// Working directory shared by the project's sessions.
  String sandbox;

  DateTime createdAt;
  DateTime updatedAt;

  String provider;
  String model;

  /// When set, the project is archived and hidden from the active list.
  DateTime? archivedAt;

  /// Project-level system prompt. New sessions created inside this project can
  /// opt in to it (新建会话页的「启用项目提示词」); it is stored per project and
  /// edited in the project edit panel.
  String systemPrompt;

  /// Whether the project carries a `.memory/` memory index.
  ///
  /// When enabled, sessions created inside the project get the memory
  /// protocol injected into their system prompt and the agent is expected to
  /// read/update `<sandbox>/.memory/` (see `core/memory_protocol.dart`).
  ///
  /// Tri-state on purpose:
  ///   - `null`  — the project predates the flag (never set). It counts as
  ///     enabled **only** when its `.memory/` directory already exists, so an
  ///     old project keeps its behaviour until the user opts in.
  ///   - `true`  — the user enabled the memory index.
  ///   - `false` — the user explicitly turned it off; always respected, even
  ///     if a `.memory/` directory is still around.
  bool? memoryEnabled;

  bool get isArchived => archivedAt != null;

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

  factory Project.fromJson(Object? value) {
    final json = asMap(value);
    return Project(
      id: asString(json['id']) ?? '',
      name: asString(json['name']) ?? '',
      description: asString(json['description']) ?? '',
      sandbox: asString(json['sandbox']) ?? '',
      createdAt: DateTime.tryParse(asString(json['created_at']) ?? '') ?? DateTime.now(),
      updatedAt: DateTime.tryParse(asString(json['updated_at']) ?? '') ?? DateTime.now(),
      provider: asString(json['provider']) ?? '',
      model: asString(json['model']) ?? '',
      systemPrompt: asString(json['system_prompt']) ?? '',
      memoryEnabled: json.containsKey('memory_enabled')
          ? asBool(json['memory_enabled'], fallback: false)
          : null,
      archivedAt: DateTime.tryParse(asString(json['archived_at']) ?? ''),
    );
  }
}
