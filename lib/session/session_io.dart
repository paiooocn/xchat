import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

import '../config/config_manager.dart';
import '../util/uuid.dart';
import '../util/xml_reader.dart';
import '../util/xml_writer.dart';
import 'session_model.dart';

class SessionIo {
  static String _fmt(DateTime dt) => dt.toUtc().toIso8601String();

  static Future<Directory> sessionsDir() async {
    final d = Directory(p.join(ConfigManager.instance.xchatDir.path, 'sessions'));
    if (!await d.exists()) await d.create(recursive: true);
    return d;
  }

  static Future<String> write(ChatSession s) async {
    final dir = await sessionsDir();
    final file = File(p.join(dir.path, '${s.id}.xml'));
    s.updated = DateTime.now().toUtc();
    final w = XmlWriter();
    w.decl();
    w.open('chat', attrs: {
      'sandbox': s.sandbox,
      'id': s.id,
      'created': _fmt(s.created),
      'updated': _fmt(s.updated),
      'max_rounds': s.maxRounds.toString(),
      if (s.title != null) 'title': s.title!,
    });
    w.open('meta');
    if (s.meta.providerId != null) {
      w.selfClose('provider', attrs: {'id': s.meta.providerId!});
    }
    if (s.meta.modelId != null) {
      w.selfClose('model', attrs: {'id': s.meta.modelId!});
    }
    w.selfClose('thinking', attrs: {'type': s.meta.thinking});
    w.selfClose('reasoning_effort', attrs: {'value': s.meta.reasoningEffort});
    w.selfClose('temperature', attrs: {'value': s.meta.temperature.toString()});
    w.selfClose('tool_output_limit', attrs: {'value': s.meta.toolOutputLimit.toString()});
    w.selfClose('context_compress_threshold', attrs: {'value': s.meta.contextCompressThreshold.toString()});
    if (s.meta.confirmMode != null) {
      w.selfClose('confirm_mode', attrs: {'value': s.meta.confirmMode!});
    }
    if (s.meta.allowSymlinks) {
      w.selfClose('allow_symlinks', attrs: {'value': 'true'});
    }
    if (s.projectId != null) {
      w.selfClose('project', attrs: {'id': s.projectId!});
    }
    if (s.tags.isNotEmpty) {
      w.open('tags');
      for (final t in s.tags) {
        w.selfClose('tag', attrs: {'value': t});
      }
      w.close('tags');
    }
    w.close('meta');

    w.cdataElement('system', s.systemPrompt, attrs: {
      'input': s.sysInput.toString(),
      'output': s.sysOutput.toString(),
      'cache': s.sysCache.toString(),
      'context': s.sysContext.toString(),
    });

    // 工具定义:无 tool_call_id 属性的 <tool name="..."/>
    for (final t in s.tools) {
      w.selfClose('tool', attrs: {
        'name': t.name,
        if (!t.enabled) 'enabled': 'false',
      });
    }

    // 消息:按原顺序写入;assistant 含 tool_calls 时,内嵌 <tool_calls><tool_call/></tool_calls>;
    // tool 消息带 tool_call_id,作为 chat 的子元素与 assistant 同级。
    for (final m in s.messages) {
      switch (m.role) {
        case Role.user:
          w.cdataElement('user', m.text);
          break;
        case Role.assistant:
          if (m.toolCalls.isEmpty) {
            w.cdataElement('assistant', m.text, attrs: m.attrs);
          } else {
            // 开 assistant,内嵌 tool_calls 子元素(顺序按 toolCalls 列表)
            w.open('assistant', attrs: m.attrs);
            w.open('tool_calls');
            for (final c in m.toolCalls) {
              // arguments 走 CDATA,避免引号/换行/特殊字符破坏属性; id/name 走属性便于检索
              w.cdataElement('tool_call', c.arguments, attrs: {
                'id': c.id,
                'name': c.name,
              });
            }
            w.close('tool_calls');
            // 原始 assistant 文本(如 "好的,我来执行")也保留为子节点,便于回看
            if (m.text.isNotEmpty) {
              w.cdataElement('text', m.text);
            }
            w.close('assistant');
          }
          break;
        case Role.tool:
          // tool 结果消息:与 assistant 同级,通过 tool_call_id/name 属性识别
          w.cdataElement('tool', m.text, attrs: m.attrs);
          break;
        case Role.system:
          break;
      }
    }

    if (s.archive.isNotEmpty) {
      w.open('archive');
      if (s.archiveSummary != null) {
        w.selfClose('summary', attrs: {'value': s.archiveSummary!});
      }
      for (final m in s.archive) {
        if (m.role == Role.user) w.cdataElement('user', m.text);
        if (m.role == Role.assistant) {
          // archive 中 assistant 也按新格式处理(若有 tool_calls)
          if (m.toolCalls.isEmpty) {
            w.cdataElement('assistant', m.text);
          } else {
            w.open('assistant');
            w.open('tool_calls');
            for (final c in m.toolCalls) {
              w.cdataElement('tool_call', c.arguments, attrs: {'id': c.id, 'name': c.name});
            }
            w.close('tool_calls');
            if (m.text.isNotEmpty) w.cdataElement('text', m.text);
            w.close('assistant');
          }
        }
        if (m.role == Role.tool) w.cdataElement('tool', m.text, attrs: m.attrs);
      }
      w.close('archive');
    }

    w.close('chat');

    await file.writeAsString(w.output, flush: true);
    return file.path;
  }

  static Future<ChatSession> read(String id) async {
    final dir = await sessionsDir();
    final file = File(p.join(dir.path, '$id.xml'));
    if (!await file.exists()) {
      throw Exception('session not found: $id');
    }
    final str = await file.readAsString();
    final root = XmlReader.parse(str);
    return _parseChat(root);
  }

  static ChatSession _parseChat(XmlElement root) {
    final s = ChatSession(
      id: root.attr('id', fallback: uuidV4()),
      sandbox: root.attr('sandbox'),
      title: root.attrs.containsKey('title') ? root.attr('title') : null,
      maxRounds: int.tryParse(root.attr('max_rounds', fallback: '20')) ?? 20,
    );
    try {
      s.created = DateTime.parse(root.attr('created'));
    } catch (_) {}
    try {
      s.updated = DateTime.parse(root.attr('updated'));
    } catch (_) {}

    final meta = root.children.firstWhere((e) => e.tag == 'meta',
        orElse: () => XmlElement(tag: 'meta'));
    for (final child in meta.children) {
      switch (child.tag) {
        case 'provider':
          s.meta.providerId = child.attr('id');
          break;
        case 'model':
          s.meta.modelId = child.attr('id');
          break;
        case 'thinking':
          s.meta.thinking = child.attr('type');
          break;
        case 'reasoning_effort':
          s.meta.reasoningEffort = child.attr('value');
          break;
        case 'temperature':
          s.meta.temperature = double.tryParse(child.attr('value')) ?? 1.0;
          break;
        case 'tool_output_limit':
          s.meta.toolOutputLimit = int.tryParse(child.attr('value')) ?? 8000;
          break;
        case 'context_compress_threshold':
          s.meta.contextCompressThreshold = double.tryParse(child.attr('value')) ?? 0.8;
          break;
        case 'confirm_mode':
          s.meta.confirmMode = child.attr('value');
          break;
        case 'allow_symlinks':
          s.meta.allowSymlinks = child.attr('value') == 'true';
          break;
        case 'project':
          s.projectId = child.attr('id');
          break;
        case 'tags':
          s.tags = child.children
              .where((c) => c.tag == 'tag')
              .map((c) => c.attr('value'))
              .where((v) => v.isNotEmpty)
              .toList();
          break;
      }
    }

    // 顶层 tool 定义与 tool 结果消息都叫 "tool",靠 tool_call_id 区分:
    //   - 出现在 <meta>/<system> 之后、messages 之前的 <tool> 且无 tool_call_id → ToolDef
    //   - 出现在 messages 区且带 tool_call_id → Role.tool 消息
    //   - 出现在 messages 区之后又出现 <tool>(无 tool_call_id)→按 tool 消息兜底
    // 按出现顺序遍历 root.children,根据是否进入 messages 区切换处理。
    bool inMessages = false;
    for (final child in root.children) {
      final tag = child.tag;
      if (tag == 'meta') continue;
      if (tag == 'system') {
        s.systemPrompt = child.text;
        s.sysInput = int.tryParse(child.attr('input')) ?? 0;
        s.sysOutput = int.tryParse(child.attr('output')) ?? 0;
        s.sysCache = int.tryParse(child.attr('cache')) ?? 0;
        s.sysContext = int.tryParse(child.attr('context')) ?? 0;
        continue;
      }
      if (tag == 'archive') {
        s.archiveSummary = child.children
            .firstWhere((e) => e.tag == 'summary',
                orElse: () => XmlElement(tag: 'summary'))
            .attr('value');
        for (final ac in child.children) {
          if (ac.tag == 'user') s.archive.add(Message(role: Role.user, text: ac.text));
          if (ac.tag == 'assistant') {
            final am = Message(role: Role.assistant, text: _extractAssistantText(ac));
            _populateAssistantToolCalls(ac, am);
            s.archive.add(am);
          }
          if (ac.tag == 'tool') {
            s.archive.add(Message(
                role: Role.tool,
                text: ac.text,
                toolCallId: ac.attr('tool_call_id'),
                toolName: ac.attr('name')));
          }
        }
        continue;
      }
      if (tag == 'tool') {
        if (child.attrs.containsKey('tool_call_id')) {
          // messages 区中的 tool 结果
          inMessages = true;
          s.messages.add(Message(
            role: Role.tool,
            text: child.text,
            toolCallId: child.attr('tool_call_id'),
            toolName: child.attr('name'),
          ));
        } else if (!inMessages) {
          // meta 之后、messages 之前的 tool 定义
          s.tools.add(ToolDef(child.attr('name'),
              enabled: child.attr('enabled', fallback: 'true') != 'false'));
        } else {
          // messages 区之后又出现 <tool>(无 tool_call_id)——按 tool 消息处理兜底
          s.messages.add(Message(
            role: Role.tool,
            text: child.text,
            toolCallId: null,
            toolName: child.attr('name'),
          ));
        }
        continue;
      }
      if (tag == 'user') {
        inMessages = true;
        s.messages.add(Message(role: Role.user, text: child.text));
        continue;
      }
      if (tag == 'assistant') {
        inMessages = true;
        final m = Message(role: Role.assistant, text: _extractAssistantText(child));
        m.input = int.tryParse(child.attr('input')) ?? 0;
        m.output = int.tryParse(child.attr('output')) ?? 0;
        m.cache = int.tryParse(child.attr('cache')) ?? 0;
        m.model = child.attrs.containsKey('model') ? child.attr('model') : null;
        _populateAssistantToolCalls(child, m);
        // 兼容旧版:若新格式未拿到 tool_calls 但 CDATA 内有 [[tool_calls]] 标记块,
        // 用旧解析路径兜底
        if (m.toolCalls.isEmpty) {
          final legacy = _parseLegacyToolCalls(child.text);
          for (final c in legacy) {
            m.toolCalls.add(c);
          }
        }
        s.messages.add(m);
        continue;
      }
      // 其他未知 tag 忽略
    }
    return s;
  }

  /// 从 assistant 元素提取纯文本:
  /// - 新格式:取 <text> 子元素的 CDATA
  /// - 旧格式:取元素 text 并剥掉 [[tool_calls]] 标记块
  static String _extractAssistantText(XmlElement assistant) {
    final tEl = assistant.children.firstWhere(
      (e) => e.tag == 'text',
      orElse: () => XmlElement(tag: '__missing__'),
    );
    if (tEl.tag == 'text') return tEl.text;
    // 旧格式:元素 text 里有 [[tool_calls]] 块,需要剥掉
    return assistant.text
        .replaceFirst(
            RegExp(r'\n?\[{2}tool_calls\]{2}\n.*?\n\[{2}/tool_calls\]{2}', dotAll: true), '')
        .trim();
  }

  /// 从 assistant 元素的 <tool_calls> 子树读出所有 <tool_call>,按出现顺序。
  static void _populateAssistantToolCalls(XmlElement assistant, Message m) {
    final tcContainer = assistant.children.firstWhere(
      (e) => e.tag == 'tool_calls',
      orElse: () => XmlElement(tag: 'tool_calls'),
    );
    if (tcContainer.tag != 'tool_calls') return;
    for (final tc in tcContainer.children) {
      if (tc.tag != 'tool_call') continue;
      final id = tc.attr('id');
      final name = tc.attr('name');
      if (id.isEmpty || name.isEmpty) continue;
      final args = tc.text.isEmpty ? '{}' : tc.text;
      m.toolCalls.add(ToolCall(id: id, name: name, arguments: args));
    }
  }

  /// 旧格式兼容:从 assistant 的 CDATA 中解析 [[tool_calls]]...[[/tool_calls]] 块。
  static List<ToolCall> _parseLegacyToolCalls(String s) {
    final m = RegExp(r'\[\[tool_calls\]\]\n(.*?)\n\[\[/tool_calls\]\]', dotAll: true)
        .firstMatch(s);
    if (m == null) return const [];
    try {
      final raw = m.group(1)!.trim();
      final list = jsonDecode(raw);
      if (list is! List) return const [];
      return list.whereType<Map>().map((c) {
        final fn = (c['function'] as Map?) ?? const {};
        final fnArgs = fn['arguments'];
        final argsJson = fnArgs is String ? fnArgs : jsonEncode(fnArgs);
        return ToolCall(
          id: c['id'] as String,
          name: (fn['name'] as String?) ?? '',
          arguments: argsJson,
        );
      }).toList();
    } catch (_) {
      return const [];
    }
  }
}
