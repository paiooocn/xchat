/// 系统提示词的两种配置方式（会话模板）。
enum SystemPromptMode {
  /// 手动多行文本输入。
  text,

  /// 从预设专长库中选择，由系统组合生成。
  expertise;

  /// XML / JSON 中的稳定写法；未知或缺失一律按 [text]（旧模板兼容）。
  String get wire => name;

  static SystemPromptMode parse(String? value) =>
      value == SystemPromptMode.expertise.wire ? SystemPromptMode.expertise : SystemPromptMode.text;
}

/// 一个预设 AI 专长：名称 + 说明 + 可直接拼接的提示词片段。
class Expertise {
  const Expertise({
    required this.id,
    required this.name,
    required this.description,
    required this.prompt,
    this.sort = 0,
    this.enabled = true,
    this.aliases = const <String>[],
  });

  final String id;
  final String name;

  /// 给用户看的说明（badge 悬停 / 长按展示）。
  final String description;

  /// 该专长贡献的系统提示词正文。
  final String prompt;

  /// 专长库中的固定排序序号（升序，越小越靠前）。
  final int sort;

  /// 停用后不再出现在模板的待选项里，也不参与组合（已存模板保留原解析结果）。
  final bool enabled;

  /// 旧版本内置 id（别名）：旧模板仍引用它们，组合时按别名命中当前专长。
  final List<String> aliases;

  /// 是否匹配 [id]（本体 id 或任一别名）。
  bool matchesId(String id) => this.id == id || aliases.contains(id);

  Expertise copyWith({
    String? id,
    String? name,
    String? description,
    String? prompt,
    int? sort,
    bool? enabled,
    List<String>? aliases,
  }) =>
      Expertise(
        id: id ?? this.id,
        name: name ?? this.name,
        description: description ?? this.description,
        prompt: prompt ?? this.prompt,
        sort: sort ?? this.sort,
        enabled: enabled ?? this.enabled,
        aliases: aliases ?? List<String>.of(this.aliases),
      );

  Map<String, Object?> toJson() => <String, Object?>{
        'id': id,
        'name': name,
        'description': description,
        'prompt': prompt,
        'sort': sort,
        'enabled': enabled,
        if (aliases.isNotEmpty) 'aliases': aliases,
      };

  factory Expertise.fromJson(Object? value) {
    final map = value is Map ? value.cast<String, Object?>() : const <String, Object?>{};
    return Expertise(
      id: _str(map['id']),
      name: _str(map['name']),
      description: _str(map['description']),
      prompt: _str(map['prompt']),
      sort: _int(map['sort']) ?? 0,
      enabled: map['enabled'] != false,
      aliases: _stringList(map['aliases']),
    );
  }

  static List<String> _stringList(Object? value) {
    if (value is! List) return const <String>[];
    return <String>[
      for (final item in value)
        if (item != null) item.toString(),
    ];
  }

  static String _str(Object? value) => value == null ? '' : value.toString();

  static int? _int(Object? value) {
    if (value is int) return value;
    if (value is num) return value.round();
    return int.tryParse(value?.toString() ?? '');
  }
}

/// 按专长库固定顺序（`sort` 升序；同序号按 id 稳定排序）排列。
List<Expertise> sortExpertiseLibrary(List<Expertise> items) {
  final sorted = List<Expertise>.of(items)
    ..sort((a, b) {
      final bySort = a.sort.compareTo(b.sort);
      return bySort != 0 ? bySort : a.id.compareTo(b.id);
    });
  return sorted;
}

/// 把选中的专长组合成系统提示词。
///
/// - 只拼接库中存在的专长（未知 id 跳过）；
/// - 顺序恒为专长库的 `sort` 升序，**与用户点击顺序无关**；
/// - 各段之间用空行 + 分隔线分隔；
/// - 未选择任何专长时返回空串（是否允许保存由调用方决定）。
String composeExpertisePrompt(Iterable<String> selectedIds, List<Expertise> library) {
  final wanted = selectedIds.where((id) => id.trim().isNotEmpty).toSet();
  if (wanted.isEmpty) return '';
  final ordered = sortExpertiseLibrary(library)
      .where((item) =>
          item.enabled &&
          (wanted.contains(item.id) || item.aliases.any(wanted.contains)))
      .toList();
  final sections = <String>[];
  for (final item in ordered) {
    final prompt = item.prompt.trim();
    if (prompt.isEmpty) continue;
    sections.add(prompt);
  }
  return sections.join('\n\n---\n\n');
}

/// 选中 id 对应的专长（按库顺序），用于 UI 展示「已选」之外的场景。
List<Expertise> selectedExpertises(Iterable<String> selectedIds, List<Expertise> library) {
  final wanted = selectedIds.toSet();
  return sortExpertiseLibrary(library)
      .where((item) =>
          item.enabled &&
          (wanted.contains(item.id) || item.aliases.any(wanted.contains)))
      .toList();
}

/// 是否至少有一个「可用」的已选专长（存在、未停用、提示词非空）。
/// 保存模板前的校验用它，而不是只看 id 集合是否为空。
bool hasUsableExpertiseSelection(Iterable<String> selectedIds, List<Expertise> library) {
  final wanted = selectedIds.toSet();
  return library.any(
    (item) =>
        item.enabled &&
        item.prompt.trim().isNotEmpty &&
        (wanted.contains(item.id) || item.aliases.any(wanted.contains)),
  );
}
