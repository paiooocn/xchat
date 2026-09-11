import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

import '../config/config_manager.dart';
import '../util/uuid.dart';

/// 项目:用于会话编组。
/// 持久化到 ~/.xchat/projects.json(单文件、简单 JSON 数组)。
class Project {
  final String id;
  String name;
  String color;     // CSS 颜色字符串,如 '#4f7cff'
  final DateTime created;
  Project({required this.id, required this.name, required this.color, DateTime? created})
      : created = created ?? DateTime.now().toUtc();

  Map<String, dynamic> toJson() => {
        'id': id,
        'name': name,
        'color': color,
        'created': created.toIso8601String(),
      };
  static Project fromJson(Map<String, dynamic> j) => Project(
        id: j['id'] as String,
        name: (j['name'] ?? '') as String,
        color: (j['color'] ?? '#4f7cff') as String,
        created: DateTime.tryParse((j['created'] ?? '') as String) ?? DateTime.now().toUtc(),
      );
}

class ProjectRepo {
  static const _defaultColors = [
    '#4f7cff', '#2bb673', '#f5a623', '#e54848',
    '#9b59b6', '#16a085', '#e67e22', '#34495e',
  ];

  static Future<File> _file() async {
    final dir = ConfigManager.instance.xchatDir;
    return File(p.join(dir.path, 'projects.json'));
  }

  static Future<List<Project>> list() async {
    final f = await _file();
    if (!await f.exists()) return [];
    try {
      final raw = await f.readAsString();
      if (raw.trim().isEmpty) return [];
      final arr = jsonDecode(raw) as List;
      return arr.map((e) => Project.fromJson(Map<String, dynamic>.from(e as Map))).toList();
    } catch (_) {
      return [];
    }
  }

  static Future<Project> create({required String name, String? color}) async {
    final list = await ProjectRepo.list();
    final c = color ?? _defaultColors[list.length % _defaultColors.length];
    final p = Project(id: uuidV4(), name: name, color: c);
    list.add(p);
    await _save(list);
    return p;
  }

  static Future<Project> rename({required String id, required String name, String? color}) async {
    final list = await ProjectRepo.list();
    final i = list.indexWhere((x) => x.id == id);
    if (i < 0) throw StateError('project not found: $id');
    list[i].name = name;
    if (color != null && color.isNotEmpty) list[i].color = color;
    await _save(list);
    return list[i];
  }

  static Future<void> delete(String id) async {
    final list = await ProjectRepo.list();
    list.removeWhere((x) => x.id == id);
    await _save(list);
  }

  static Future<void> _save(List<Project> list) async {
    final f = await _file();
    await f.writeAsString(
      const JsonEncoder.withIndent('  ').convert(list.map((x) => x.toJson()).toList()),
      flush: true,
    );
  }
}
