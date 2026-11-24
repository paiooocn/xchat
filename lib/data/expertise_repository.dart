import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart' show rootBundle;

import '../core/app_paths.dart';
import '../models/expertise.dart';
import 'atomic_file.dart';

/// 预设 AI 专长库的内置来源（会话模板「AI专长」模式）。
const String kExpertiseAsset = 'assets/expertises.json';

/// 读取并维护 AI 专长库：内置 `assets/expertises.json` + 用户改动
/// （`<root>/expertises.json`）。
///
/// 用户文件的语义：
/// - `items`：当前完整列表（含内置项被编辑/停用后的版本、用户新增项）；
/// - `deleted`：被删除的**内置** id 墓碑（否则内置项会随基础库重新出现）。
///
/// 内置资源缺失 / 损坏时基础库为空；用户文件缺失时退化为纯内置库。
class ExpertiseRepository {
  ExpertiseRepository(this.paths);

  final AppPaths paths;

  File get _userFile => File(paths.expertiseFile);

  /// 有效列表 = 内置库 ⊕ 用户改动（同 id 覆盖、未知 id 追加、墓碑删除）。
  Future<List<Expertise>> load() async {
    final base = await loadBundled();
    final overrides = await _readUserFile();
    return mergeExpertiseLibraries(base, overrides.items, overrides.deleted);
  }

  /// 保存管理页编辑后的完整列表（含停用项；删除即从列表中去掉）。
  Future<void> save(List<Expertise> effective) async {
    final base = await loadBundled();
    final baseIds = base.map((e) => e.id).toSet();
    final keptIds = effective.map((e) => e.id).toSet();
    final deleted = baseIds.where((id) => !keptIds.contains(id)).toList()..sort();
    final payload = <String, Object?>{
      'deleted': deleted,
      'items': <Object?>[for (final item in effective) item.toJson()],
    };
    await writeAtomic(
      paths.expertiseFile,
      const JsonEncoder.withIndent('  ').convert(payload),
    );
  }

  /// 只读内置资源（用于管理页识别哪些是内置项，以及生成删除墓碑）。
  static Future<List<Expertise>> loadBundled({String assetPath = kExpertiseAsset}) async {
    try {
      return parseExpertiseAsset(await rootBundle.loadString(assetPath));
    } catch (_) {
      return const <Expertise>[];
    }
  }

  /// 解析 JSON：顶层数组或 `{ "expertises": [...] }` 包装都接受；缺 id/名称/
  /// 提示词的条目跳过。返回结果已按 [sortExpertiseLibrary] 排好序。
  static List<Expertise> parseExpertiseAsset(String raw) {
    if (raw.trim().isEmpty) return const <Expertise>[];
    final Object? decoded;
    try {
      decoded = jsonDecode(raw);
    } catch (_) {
      return const <Expertise>[];
    }
    return parseExpertiseItems(_itemsOf(decoded));
  }

  /// 内置库与用户改动合并：同 id 覆盖、新 id 追加、`deleted` 中的内置 id 移除。
  static List<Expertise> mergeExpertiseLibraries(
    List<Expertise> base,
    List<Expertise> overrides,
    Set<String> deleted,
  ) {
    final byId = <String, Expertise>{};
    for (final item in overrides) {
      if (item.id.trim().isEmpty) continue;
      byId[item.id] = item;
    }
    final merged = <Expertise>[];
    for (final item in base) {
      if (deleted.contains(item.id)) continue;
      var override = byId.remove(item.id);
      // 兼容：用户改动里写的是旧 id（别名）时，覆盖到当前内置项。
      if (override == null) {
        for (final entry in byId.entries.toList()) {
          if (item.matchesId(entry.key)) {
            override = byId.remove(entry.key);
            break;
          }
        }
      }
      merged.add(override ?? item);
    }
    merged.addAll(byId.values);
    return sortExpertiseLibrary(merged);
  }

  static List<Expertise> parseExpertiseItems(Object? list) {
    if (list is! List) return const <Expertise>[];
    final items = <Expertise>[];
    for (final entry in list) {
      final expertise = Expertise.fromJson(entry);
      if (expertise.id.trim().isEmpty) continue;
      if (expertise.name.trim().isEmpty) continue;
      if (expertise.prompt.trim().isEmpty) continue;
      items.add(expertise);
    }
    return sortExpertiseLibrary(items);
  }

  static Object? _itemsOf(Object? decoded) =>
      decoded is Map ? decoded['expertises'] ?? decoded['items'] : decoded;

  Future<({List<Expertise> items, Set<String> deleted})> _readUserFile() async {
    try {
      final raw = await _userFile.readAsString();
      if (raw.trim().isEmpty) return (items: const <Expertise>[], deleted: const <String>{});
      final decoded = jsonDecode(raw);
      if (decoded is! Map) {
        if (decoded is List) {
          return (items: parseExpertiseItems(decoded), deleted: const <String>{});
        }
        return (items: const <Expertise>[], deleted: const <String>{});
      }
      final items = parseExpertiseItems(decoded['items'] ?? decoded['expertises']);
      final deleted = <String>{
        for (final value in decoded['deleted'] is List ? decoded['deleted'] as List : const <Object?>[])
          if (value != null) value.toString(),
      };
      return (items: items, deleted: deleted);
    } catch (_) {
      return (items: const <Expertise>[], deleted: const <String>{});
    }
  }
}
