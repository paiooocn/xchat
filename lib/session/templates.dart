import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:xml/xml.dart';

import '../config/config_manager.dart';
import '../util/uuid.dart';
import 'session_io.dart';
import 'session_model.dart';

class Template {
  final String id;
  final String name;
  final String description;
  final String xml;
  /// 模板内声明的 {{var}} 列表(从 XML 文本提取,排序去重)
  final List<String> vars;
  /// 是否用户自定义(false = 内置,只读)
  final bool editable;

  Template({
    required this.id,
    required this.name,
    required this.description,
    required this.xml,
    List<String>? vars,
    this.editable = false,
  }) : vars = vars ?? _extractVars(xml);

  /// 从 XML 文本提取 {{name}} 变量
  static List<String> _extractVars(String xml) {
    final re = RegExp(r'\{\{\s*([a-zA-Z_][a-zA-Z0-9_]*)\s*\}\}');
    final set = <String>{};
    for (final m in re.allMatches(xml)) {
      set.add(m.group(1)!);
    }
    final out = set.toList()..sort();
    return out;
  }

  String render(Map<String, String> vars) {
    var out = xml;
    vars.forEach((k, v) {
      out = out.replaceAll('{{$k}}', v);
    });
    return out;
  }
}

class TemplateRepo {
  /// 用户模板目录
  static Future<Directory> _userDir() async {
    final d = Directory(p.join(ConfigManager.instance.xchatDir.path, 'templates'));
    if (!await d.exists()) await d.create(recursive: true);
    return d;
  }

  /// id → 文件名(用户模板);只接受 [a-z0-9-_]
  static String _safeFileName(String id) {
    final base = id.replaceAll(RegExp(r'[^a-zA-Z0-9_\-]'), '_');
    return '$base.xml';
  }

  static Future<List<Template>> list() async {
    final dir = await _userDir();
    final out = <Template>[];
    for (final t in _builtinTemplates()) out.add(t);
    final entries = await dir.list().where((e) => e is File && e.path.endsWith('.xml')).toList();
    for (final e in entries) {
      try {
        final xml = await File(e.path).readAsString();
        final doc = XmlDocument.parse(xml);
        final root = doc.rootElement;
        final name = root.getAttribute('name') ?? p.basenameWithoutExtension(e.path);
        final desc = root.getAttribute('description') ?? '';
        out.add(Template(
          id: 'user:${p.basenameWithoutExtension(e.path)}',
          name: name,
          description: desc,
          xml: xml,
          editable: true,
        ));
      } catch (_) {}
    }
    return out;
  }

  static Future<Template?> get(String id) async {
    final list = await TemplateRepo.list();
    for (final t in list) {
      if (t.id == id) return t;
    }
    return null;
  }

  /// 保存用户模板。id 已存在则覆盖,不存在则创建新文件。
  /// name/description 写为 <template name="..." description="..."> 顶层属性。
  static Future<Template> save({
    required String id,
    required String name,
    required String description,
    required String xml,
  }) async {
    if (!id.startsWith('user:')) {
      throw ArgumentError('id must start with "user:"');
    }
    final slug = id.substring('user:'.length);
    if (slug.isEmpty) {
      throw ArgumentError('id slug is empty');
    }
    // 用 XmlBuilder 重新序列化,确保 name/description 写到顶层属性,
    // 即使 H5 直接传裸 XML 也能被规范化。
    final doc = XmlDocument.parse(xml);
    final root = doc.rootElement;
    root.setAttribute('name', name);
    root.setAttribute('description', description);
    final normalized = doc.toXmlString(pretty: true, indent: '  ');

    final dir = await _userDir();
    final file = File(p.join(dir.path, _safeFileName(slug)));
    await file.writeAsString(normalized, flush: true);

    return Template(
      id: id,
      name: name,
      description: description,
      xml: normalized,
      editable: true,
    );
  }

  /// 删除用户模板。内置抛错。
  static Future<void> delete(String id) async {
    if (!id.startsWith('user:')) {
      throw ArgumentError('cannot delete builtin template');
    }
    final dir = await _userDir();
    final file = File(p.join(dir.path, _safeFileName(id.substring('user:'.length))));
    if (await file.exists()) await file.delete();
  }

  /// "复制为我的模板":从任意模板 id 复制,生成新 user id。
  static Future<Template> duplicate(String sourceId, {required String newName}) async {
    final src = await get(sourceId);
    if (src == null) throw StateError('source template not found: $sourceId');
    final slug = '${DateTime.now().millisecondsSinceEpoch}';
    return save(
      id: 'user:$slug',
      name: newName.isEmpty ? '${src.name} (副本)' : newName,
      description: src.description,
      xml: src.xml,
    );
  }

  /// 列出模板中声明的变量名
  static Future<List<String>> listVars(String id) async {
    final t = await get(id);
    return t?.vars ?? [];
  }

  static Future<ChatSession> create({
    required Template template,
    required Map<String, String> vars,
    String? sandbox,
    String? providerId,
    String? modelId,
    int? maxRounds,
    ChatMeta? metaOverride,
    String? title,
  }) async {
    final rendered = template.render(vars);
    final doc = XmlDocument.parse(rendered);
    final root = doc.rootElement;
    final sysEl = root.findElements('system').firstOrNull;
    final systemPrompt = sysEl?.innerText ?? '';

    final List<String> tools;
    final toolsContainer = root.findElements('tools').firstOrNull;
    if (toolsContainer != null) {
      tools = toolsContainer.findElements('tool').map((e) => e.getAttribute('name') ?? '').where((s) => s.isNotEmpty).toList();
    } else {
      tools = root.findElements('tool').map((e) => e.getAttribute('name') ?? '').where((s) => s.isNotEmpty).toList();
    }

    final maxR = maxRounds ??
        int.tryParse(
            root.findElements('meta').firstOrNull?.findElements('max_rounds').firstOrNull?.getAttribute('value') ?? '20') ??
        20;

    final meta = metaOverride ?? ChatMeta();
    meta.providerId = providerId ?? meta.providerId;
    meta.modelId = modelId ?? meta.modelId;

    // 从 provider.models 取 model 级的 thinking/reasoning_effort/temperature,
    // 仅在调用方未显式提供 metaOverride 时填充(metaOverride 表示调用方完全自定义,不应被覆盖)。
    if (metaOverride == null && meta.providerId != null && meta.modelId != null) {
      final providers = (ConfigManager.instance.data['providers'] as List?) ?? [];
      for (final raw in providers) {
        if (raw is Map && raw['id'] == meta.providerId) {
          final models = (raw['models'] as List?) ?? [];
          for (final mRaw in models) {
            if (mRaw is Map && mRaw['id'] == meta.modelId) {
              final t = (mRaw['thinking'] as String?)?.trim();
              final r = (mRaw['reasoning_effort'] as String?)?.trim();
              final temp = (mRaw['temperature'] as num?)?.toDouble();
              if (t != null && t.isNotEmpty) meta.thinking = t;
              if (r != null && r.isNotEmpty) meta.reasoningEffort = r;
              if (temp != null) meta.temperature = temp;
              break;
            }
          }
          break;
        }
      }
    }

    final s = ChatSession(
      id: uuidV4(),
      sandbox: sandbox ?? Directory.current.path,
      title: title,
      maxRounds: maxR,
      meta: meta,
      systemPrompt: systemPrompt,
      tools: tools.map((n) => ToolDef(n)).toList(),
    );
    await SessionIo.write(s);
    return s;
  }

  static List<Template> _builtinTemplates() {
    return [
      Template(
        id: 'builtin:blank',
        name: '空白',
        description: '空模板',
        xml: '''<?xml version="1.0" encoding="UTF-8"?>
<template name="空白" description="空模板">
<meta><max_rounds value="20"/></meta>
<system><![CDATA[]]></system>
<tools/>
</template>''',
      ),
      Template(
        id: 'builtin:coder',
        name: 'Coder',
        description: '编程助手（sandbox: {{sandbox}}）',
        xml: '''<?xml version="1.0" encoding="UTF-8"?>
<template name="Coder" description="编程助手">
<meta>
<model_param><thinking type="enabled"/><temperature value="0.2"/></model_param>
<max_rounds value="30"/>
</meta>
<system><![CDATA[
你是资深 {{language}} 工程师。工作目录: {{sandbox}}。
- 修改前先 read_file / grep 了解现状
- 写代码后用 shell 自测
- 不确定就问
]]></system>
<tools>
<tool name="read_file"/>
<tool name="write_file"/>
<tool name="edit_file"/>
<tool name="list_dir"/>
<tool name="glob"/>
<tool name="grep"/>
<tool name="shell"/>
</tools>
</template>''',
      ),
      Template(
        id: 'builtin:research',
        name: 'Research',
        description: '研究助手',
        xml: '''<?xml version="1.0" encoding="UTF-8"?>
<template name="Research" description="研究助手">
<meta><max_rounds value="15"/></meta>
<system><![CDATA[
你是研究助手。给出有引用、有依据的回答。
]]></system>
<tools>
<tool name="shell"/>
<tool name="grep"/>
<tool name="glob"/>
<tool name="read_file"/>
</tools>
</template>''',
      ),
    ];
  }
}
