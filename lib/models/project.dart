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
      archivedAt: DateTime.tryParse(asString(json['archived_at']) ?? ''),
    );
  }
}
