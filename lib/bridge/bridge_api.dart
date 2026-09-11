import 'dart:async';
import 'dart:io';

import 'package:path/path.dart' as p;

import '../agent/react_loop.dart';
import '../config/blocklist_loader.dart';
import '../config/config_manager.dart';
import '../config/fx_rates.dart';
import '../config/provider_repo.dart';
import '../session/project_repo.dart';
import '../session/session_io.dart';
import '../session/session_list.dart';
import '../session/session_ops.dart';
import '../session/session_model.dart';
import '../session/templates.dart';
import 'bridge_events.dart';

class BridgeApi {
  /// 注入 H5 JS：window.xchat
  static const String kXchatJs = r'''
window.xchat = (function() {
  function call(method, args) {
    return new Promise(function(resolve, reject) {
      var cb = '_xchat_cb_' + Date.now() + '_' + Math.floor(Math.random()*1e6);
      window[cb] = function(ok, payload) {
        delete window[cb];
        if (ok) resolve(payload); else reject(payload);
      };
      if (window._xchat_native && window._xchat_native.postMessage) {
        window._xchat_native.postMessage(JSON.stringify({method: method, args: args || {}, cb: cb}));
      } else {
        reject({error: 'bridge not ready'});
      }
    });
  }
  function on(event, handler) {
    if (!window._xchat_events) window._xchat_events = {};
    if (!window._xchat_events[event]) window._xchat_events[event] = [];
    window._xchat_events[event].push(handler);
  }
  window._xchat_dispatch = function(event, payload) {
    var arr = (window._xchat_events && window._xchat_events[event]) || [];
    for (var i = 0; i < arr.length; i++) arr[i](payload);
  };
  return {
    config: {
      get: function() { return call('config.get', {}); },
      set: function(p) { return call('config.set', {patch: p}); },
      refreshFx: function() { return call('config.refreshFx', {}); },
      getBlocklist: function() { return call('config.getBlocklist', {}); },
      setBlocklist: function(p) { return call('config.setBlocklist', {patch: p}); },
      setConfirmMode: function(m) { return call('config.setConfirmMode', {mode: m}); },
      setEditor: function(e) { return call('config.setEditor', {editor: e}); },
    },
    sessions: {
      list: function(q) { return call('sessions.list', {query: q || ''}); },
      get: function(id) { return call('sessions.get', {id: id}); },
      create: function(p) { return call('sessions.create', p); },
      delete: function(id) { return call('sessions.delete', {id: id}); },
      clone: function(id) { return call('sessions.clone', {id: id}); },
      cloneMeta: function(id) { return call('sessions.cloneMeta', {id: id}); },
      resend: function(id, text) { return call('sessions.resend', {id: id, text: text}); },
      openInEditor: function(id) { return call('sessions.openInEditor', {id: id}); },
      updateMeta: function(id, patch) { return call('sessions.updateMeta', {id: id, patch: patch}); },
      listTemplates: function() { return call('sessions.listTemplates', {}); },
      getTemplate: function(id) { return call('sessions.getTemplate', {id: id}); },
    },
    templates: {
      list: function() { return call('templates.list', {}); },
      get: function(id) { return call('templates.get', {id: id}); },
      save: function(p) { return call('templates.save', p); },
      delete: function(id) { return call('templates.delete', {id: id}); },
      duplicate: function(id, name) { return call('templates.duplicate', {id: id, name: name || ''}); },
      listVars: function(id) { return call('templates.listVars', {id: id}); },
      openInEditor: function(id) { return call('templates.openInEditor', {id: id}); },
    },
    chat: {
      send: function(sid, text) { return call('chat.send', {sessionId: sid, text: text}); },
      stop: function(sid) { return call('chat.stop', {sessionId: sid}); },
      confirmTool: function(sid, cid, decision) { return call('chat.confirmTool', {sessionId: sid, callId: cid, decision: decision}); },
    },
    events: { on: on }
  };
})();
''';

  /// 处理 H5 调过来的 method
  static Future<Map<String, dynamic>> handle(String method, Map<String, dynamic> args) async {
    try {
      switch (method) {
        // config
        case 'config.get':
          return {'ok': true, 'payload': ConfigManager.instance.data};
        case 'config.set':
          final patch = (args['patch'] as Map?) ?? {};
          final res = await ConfigManager.instance.patch(Map<String, dynamic>.from(patch));
          return {'ok': true, 'payload': res};
        case 'config.refreshFx':
          await FxRates.refresh();
          return {'ok': true, 'payload': {'fetched_at': FxRates.fetchedAt, 'rates': FxRates.rates}};
        case 'config.getBlocklist':
          final bl = BlocklistLoader.instance.current;
          return {
            'ok': true,
            'payload': {
              'layer_a': bl.layerA.map((r) => {'pattern': r.pattern, 'note': r.note}).toList(),
              'layer_b': bl.layerB.map((r) => {'pattern': r.pattern, 'note': r.note}).toList(),
              'layer_b_exceptions': bl.layerBExceptions.map((r) => {'pattern': r.pattern, 'note': r.note}).toList(),
            }
          };
        case 'config.setBlocklist':
          final patch = (args['patch'] as Map?) ?? {};
          final la = (patch['layer_a'] as List? ?? []).map((e) => BlockRule(((e as Map)['pattern'] ?? '').toString(), ((e['note'] ?? '').toString()))).toList();
          final lb = (patch['layer_b'] as List? ?? []).map((e) => BlockRule(((e as Map)['pattern'] ?? '').toString(), ((e['note'] ?? '').toString()))).toList();
          final lbe = (patch['layer_b_exceptions'] as List? ?? []).map((e) => BlockRule(((e as Map)['pattern'] ?? '').toString(), ((e['note'] ?? '').toString()))).toList();
          await BlocklistLoader.instance.save(layerA: la, layerB: lb, layerBExceptions: lbe);
          return {'ok': true, 'payload': {}};
        case 'config.setConfirmMode':
          final m = (args['mode'] ?? 'normal').toString();
          await ConfigManager.instance.patch({'ui': {'confirm_mode': m}});
          BridgeEvents.emit('confirm_mode_changed', {'mode': m});
          return {'ok': true, 'payload': {'mode': m}};
        case 'config.setEditor':
          // null 或空字符串都视作"未配置"(回退到 $EDITOR / vi)。
          final raw = args['editor'];
          final editor = (raw is String) ? raw.trim() : null;
          await ConfigManager.instance.patch({'ui': {'editor': (editor == null || editor.isEmpty) ? null : editor}});
          BridgeEvents.emit('editor_changed', {'editor': editor});
          return {'ok': true, 'payload': {'editor': editor}};

        // sessions
        case 'sessions.list':
          final q = (args['query'] ?? '').toString();
          final tag = (args['tag'] as String?)?.trim();
          final projectId = (args['project_id'] as String?)?.trim();
          final list = q.isEmpty
              ? await SessionList.list(tag: tag, projectId: projectId)
              : await SessionList.search(q, tag: tag, projectId: projectId);
          return {
            'ok': true,
            'payload': list
                .map((it) => {
                      'id': it.id,
                      'updated': it.updated.toIso8601String(),
                      'created': it.created.toIso8601String(),
                      'sandbox': it.sandbox,
                      'title': it.title,
                      'provider_id': it.providerId,
                      'model_id': it.modelId,
                      'total_input': it.totalInput,
                      'total_output': it.totalOutput,
                      'total_cache': it.totalCache,
                      'project_id': it.projectId,
                      'tags': it.tags,
                    })
                .toList(),
          };
        case 'sessions.get':
          final id = args['id'] as String;
          final s = await SessionIo.read(id);
          return {'ok': true, 'payload': _serialize(s)};
        case 'sessions.create':
          final p = (args as Map).cast<String, dynamic>();
          final tplId = p['template_id'] as String;
          final vars = Map<String, String>.from((p['vars'] as Map?)?.map((k, v) => MapEntry(k.toString(), v.toString())) ?? {});
          final tpl = await TemplateRepo.get(tplId);
          if (tpl == null) return {'ok': false, 'payload': {'error': 'template not found'}};
          final s = await TemplateRepo.create(
            template: tpl,
            vars: vars,
            sandbox: p['sandbox'] as String?,
            providerId: p['provider_id'] as String?,
            modelId: p['model_id'] as String?,
            maxRounds: p['max_rounds'] as int?,
            title: p['title'] as String?,
          );
          // C 增量:创建后立即写入 project/tags
          final pid = p['project_id'] as String?;
          if (pid != null && pid.isNotEmpty) {
            s.projectId = pid;
          }
          final tagsRaw = p['tags'] as List?;
          if (tagsRaw != null) {
            s.tags = tagsRaw
                .map((e) => e.toString().trim().toLowerCase())
                .where((e) => e.isNotEmpty)
                .toSet()
                .toList();
          }
          if ((s.projectId != null) || s.tags.isNotEmpty) {
            await SessionIo.write(s);
          }
          return {'ok': true, 'payload': {'id': s.id}};
        case 'sessions.delete':
          await SessionList.delete(args['id'] as String);
          return {'ok': true, 'payload': {}};
        case 'sessions.clone':
          final s = await SessionOps.cloneFull(args['id'] as String);
          return {'ok': true, 'payload': {'id': s.id}};
        case 'sessions.cloneMeta':
          // 复制目标会话的 chat 属性(沙箱/max_rounds)、meta(thinking/reasoning_effort/temperature
          // /provider_id/model_id/confirm_mode/...)、system 提示、tools、项目归属、tags,
          // 不复制 messages/archive。落盘后返回新 id。
          final src = await SessionOps.cloneEmpty(args['id'] as String);
          await SessionIo.write(src);
          return {'ok': true, 'payload': {'id': src.id}};
        case 'sessions.resend':
          final s = await SessionOps.resend(args['id'] as String, (args['text'] ?? '').toString());
          return {'ok': true, 'payload': {'id': s.id}};
        case 'sessions.openInEditor':
          return await _openInEditor(args['id'] as String);
        case 'sessions.updateMeta':
          final id = args['id'] as String;
          final patch = (args['patch'] as Map).cast<String, dynamic>();
          final s = await SessionIo.read(id);
          patch.forEach((k, v) {
            switch (k) {
              case 'provider_id':
                s.meta.providerId = v as String?;
                break;
              case 'model_id':
                s.meta.modelId = v as String?;
                break;
              case 'max_rounds':
                s.maxRounds = v as int;
                break;
              case 'thinking':
                s.meta.thinking = v as String;
                break;
              case 'reasoning_effort':
                s.meta.reasoningEffort = v as String;
                break;
              case 'temperature':
                s.meta.temperature = (v as num).toDouble();
                break;
              case 'confirm_mode':
                s.meta.confirmMode = v as String?;
                break;
            }
          });
          await SessionIo.write(s);
          return {'ok': true, 'payload': {}};
        case 'sessions.listTemplates':
        case 'templates.list':
          final list = await TemplateRepo.list();
          return {
            'ok': true,
            'payload': list
                .map((t) => {
                      'id': t.id,
                      'name': t.name,
                      'description': t.description,
                      'editable': t.editable,
                      'vars': t.vars,
                    })
                .toList()
          };
        case 'sessions.getTemplate':
        case 'templates.get':
          final t = await TemplateRepo.get(args['id'] as String);
          if (t == null) return {'ok': false, 'payload': {'error': 'not found'}};
          return {
            'ok': true,
            'payload': {
              'id': t.id,
              'name': t.name,
              'description': t.description,
              'xml': t.xml,
              'editable': t.editable,
              'vars': t.vars,
            }
          };
        case 'templates.save':
          try {
            final p = (args as Map).cast<String, dynamic>();
            var id = (p['id'] as String?) ?? '';
            // 允许 H5 在新建时不传 id,服务端自动生成 user:<timestamp>
            if (id.isEmpty) {
              id = 'user:${DateTime.now().millisecondsSinceEpoch}';
            } else if (!id.startsWith('user:')) {
              return {'ok': false, 'payload': {'error': 'id must start with "user:"'}};
            }
            final t = await TemplateRepo.save(
              id: id,
              name: (p['name'] ?? '').toString(),
              description: (p['description'] ?? '').toString(),
              xml: (p['xml'] ?? '').toString(),
            );
            return {
              'ok': true,
              'payload': {
                'id': t.id,
                'name': t.name,
                'description': t.description,
                'xml': t.xml,
                'editable': t.editable,
                'vars': t.vars,
              }
            };
          } catch (e) {
            return {'ok': false, 'payload': {'error': e.toString()}};
          }
        case 'templates.delete':
          try {
            await TemplateRepo.delete(args['id'] as String);
            return {'ok': true, 'payload': {}};
          } catch (e) {
            return {'ok': false, 'payload': {'error': e.toString()}};
          }
        case 'templates.duplicate':
          try {
            final newName = (args['name'] ?? '').toString();
            final t = await TemplateRepo.duplicate(args['id'] as String, newName: newName);
            return {
              'ok': true,
              'payload': {
                'id': t.id,
                'name': t.name,
                'description': t.description,
                'xml': t.xml,
                'editable': t.editable,
                'vars': t.vars,
              }
            };
          } catch (e) {
            return {'ok': false, 'payload': {'error': e.toString()}};
          }
        case 'templates.listVars':
          final list = await TemplateRepo.listVars(args['id'] as String);
          return {'ok': true, 'payload': list};
        case 'templates.openInEditor':
          return await _openTemplateInEditor(args['id'] as String);

        // C 增量:会话标签 / 项目编组
        case 'sessions.setTags':
          try {
            final id = args['id'] as String;
            final tags = ((args['tags'] as List?) ?? [])
                .map((e) => e.toString().trim().toLowerCase())
                .where((e) => e.isNotEmpty)
                .toSet()
                .toList();
            final s = await SessionIo.read(id);
            s.tags = tags;
            await SessionIo.write(s);
            return {'ok': true, 'payload': {'tags': tags}};
          } catch (e) {
            return {'ok': false, 'payload': {'error': e.toString()}};
          }
        case 'sessions.setProject':
          try {
            final id = args['id'] as String;
            // null/空字符串 = 移出项目
            final pid = args['project_id'] as String?;
            final s = await SessionIo.read(id);
            s.projectId = (pid != null && pid.isNotEmpty) ? pid : null;
            await SessionIo.write(s);
            return {'ok': true, 'payload': {'project_id': s.projectId}};
          } catch (e) {
            return {'ok': false, 'payload': {'error': e.toString()}};
          }
        case 'sessions.listTags':
          // 扫描所有会话,聚合标签并返回计数
          final all = await SessionList.list();
          final counts = <String, int>{};
          for (final it in all) {
            for (final t in it.tags) {
              counts[t] = (counts[t] ?? 0) + 1;
            }
          }
          final entries = counts.entries.toList()
            ..sort((a, b) => b.value.compareTo(a.value));
          return {
            'ok': true,
            'payload': entries.map((e) => {'name': e.key, 'count': e.value}).toList(),
          };

        // 项目 CRUD
        case 'projects.list':
          final list = await ProjectRepo.list();
          return {
            'ok': true,
            'payload': list
                .map((p) => {
                      'id': p.id,
                      'name': p.name,
                      'color': p.color,
                      'created': p.created.toIso8601String(),
                    })
                .toList(),
          };
        case 'projects.create':
          try {
            final name = (args['name'] ?? '').toString().trim();
            if (name.isEmpty) return {'ok': false, 'payload': {'error': 'name required'}};
            final p = await ProjectRepo.create(name: name, color: args['color'] as String?);
            return {'ok': true, 'payload': {'id': p.id, 'name': p.name, 'color': p.color}};
          } catch (e) {
            return {'ok': false, 'payload': {'error': e.toString()}};
          }
        case 'projects.rename':
          try {
            final p = await ProjectRepo.rename(
              id: args['id'] as String,
              name: (args['name'] ?? '').toString(),
              color: args['color'] as String?,
            );
            return {'ok': true, 'payload': {'id': p.id, 'name': p.name, 'color': p.color}};
          } catch (e) {
            return {'ok': false, 'payload': {'error': e.toString()}};
          }
        case 'projects.delete':
          try {
            await ProjectRepo.delete(args['id'] as String);
            // 同步:把隶属该项目的会话的 projectId 清空
            final all = await SessionList.list();
            for (final it in all) {
              if (it.projectId == args['id'] as String) {
                final s = await SessionIo.read(it.id);
                s.projectId = null;
                await SessionIo.write(s);
              }
            }
            return {'ok': true, 'payload': {}};
          } catch (e) {
            return {'ok': false, 'payload': {'error': e.toString()}};
          }

        // B 增量:provider/model CRUD + test
        case 'providers.list':
          final list = await ProviderRepo.list();
          return {
            'ok': true,
            'payload': list.map(_providerToJson).toList(),
          };
        case 'providers.get':
          final p = await ProviderRepo.get(args['id'] as String);
          if (p == null) return {'ok': false, 'payload': {'error': 'not found'}};
          return {'ok': true, 'payload': _providerToJson(p)};
        case 'providers.upsert':
          try {
            final p = (args as Map).cast<String, dynamic>();
            final spec = _providerFromJson(p);
            if (spec.id.trim().isEmpty) {
              return {'ok': false, 'payload': {'error': 'id required'}};
            }
            await ProviderRepo.upsert(spec);
            return {'ok': true, 'payload': {'id': spec.id}};
          } catch (e) {
            return {'ok': false, 'payload': {'error': e.toString()}};
          }
        case 'providers.delete':
          try {
            await ProviderRepo.delete(args['id'] as String);
            return {'ok': true, 'payload': {}};
          } catch (e) {
            return {'ok': false, 'payload': {'error': e.toString()}};
          }
        case 'providers.test':
          try {
            final res = await ProviderRepo.test(
              args['id'] as String,
              modelId: args['model_id'] as String?,
            );
            return {'ok': true, 'payload': res};
          } catch (e) {
            return {'ok': false, 'payload': {'error': e.toString()}};
          }

        // chat
        case 'chat.send':
          final sid = args['sessionId'] as String;
          final text = (args['text'] ?? '').toString();
          // 修复(对话卡死真元凶 #5): chat.send 在 await SessionIo.read(sid) 时如果 IO
          // 阻塞(杀毒软件独占、磁盘 IO hang、远程挂载断连),这个 await 会无限等待,
          // 而前端 await RPC 还没返回 → input.value 已空 + 没有任何 UI 反馈,
          // 用户看到的就是"卡死"。同时 ReactLoop.run 头部再次 await SessionIo.write
          // 也可能在 try/catch 不抛错的情况下 hang,前端 setRunning(true) 永远等不到。
          // 解决:chat.send 只把任务丢给后台,ReactLoop.run 内部自己 read + 失败处理;
          // 这样 RPC 立即返回,前端可以立刻显示"已发送"状态。
          // ignore: unawaited_futures
          ReactLoop.runById(sid, text);
          return {'ok': true, 'payload': {}};
        case 'chat.stop':
          ReactLoop.stop();
          return {'ok': true, 'payload': {}};
        case 'chat.confirmTool':
          final sid = args['sessionId'] as String;
          final cid = args['callId'] as String;
          final decision = (args['decision'] as Map?) ?? {};
          BridgeEvents.resolveConfirm(sid, cid, Map<String, dynamic>.from(decision));
          return {'ok': true, 'payload': {}};
        case 'chat.ready':
          // 修复 #4: WebView 端 JS mount 完成后通知 Dart,把 ready 之前缓冲的事件
          // 一次性回灌给前端,前端就能补齐 setRunning(false) 所需的 done/error/stopped。
          final pending = BridgeEvents.drainPending();
          return {'ok': true, 'payload': {'pending': pending}};

        default:
          return {'ok': false, 'payload': {'error': 'unknown method: $method'}};
      }
    } catch (e, st) {
      return {'ok': false, 'payload': {'error': '$e', 'stack': st.toString()}};
    }
  }

  static Map<String, dynamic> _serialize(ChatSession s) {
    return {
      'id': s.id,
      'sandbox': s.sandbox,
      'title': s.title,
      'created': s.created.toIso8601String(),
      'updated': s.updated.toIso8601String(),
      'max_rounds': s.maxRounds,
      'meta': {
        'provider_id': s.meta.providerId,
        'model_id': s.meta.modelId,
        'thinking': s.meta.thinking,
        'reasoning_effort': s.meta.reasoningEffort,
        'temperature': s.meta.temperature,
        'tool_output_limit': s.meta.toolOutputLimit,
        'context_compress_threshold': s.meta.contextCompressThreshold,
        'confirm_mode': s.meta.confirmMode,
      },
      'system_prompt': s.systemPrompt,
      'sys_input': s.sysInput,
      'sys_output': s.sysOutput,
      'sys_cache': s.sysCache,
      'sys_context': s.sysContext,
      'tools': s.tools.map((t) => {'name': t.name, 'enabled': t.enabled}).toList(),
      'messages': s.messages.map((m) => {
        'role': m.role.name,
        'text': m.text,
        'tool_call_id': m.toolCallId,
        'tool_name': m.toolName,
        'input': m.input,
        'output': m.output,
        'cache': m.cache,
        'model': m.model,
        'tool_calls': m.toolCalls.map((c) => {'id': c.id, 'name': c.name, 'arguments': c.arguments}).toList(),
      }).toList(),
    };
  }

  static Future<Map<String, dynamic>> _openInEditor(String id) async {
    final dir = await SessionIo.sessionsDir();
    final path = '${dir.path}/$id.xml';
    try {
      final (editor, args) = _resolveEditor(path);
      final proc = await Process.start(editor, args);
      BridgeEvents.emit('editor_opened', {'id': id, 'editor': editor});
      // 不等待退出；这里简化为 fire-and-forget。后续可监听文件 mtime
      unawaited(proc.exitCode.then((code) {
        BridgeEvents.emit('file_changed', {'id': id, 'path': path});
      }));
      return {'ok': true, 'payload': {'editor': editor, 'path': path}};
    } catch (e) {
      return {'ok': false, 'payload': {'error': '$e'}};
    }
  }

  /// 模板编辑器:把模板内容写到 ~/.xchat/templates/<id>.xml(已存在)
  /// 内置模板则先复制为 user 副本,再开 editor。
  static Future<Map<String, dynamic>> _openTemplateInEditor(String id) async {
    try {
      String path;
      if (id.startsWith('user:')) {
        final slug = id.substring('user:'.length);
        final dir = Directory(p.join(ConfigManager.instance.xchatDir.path, 'templates'));
        if (!await dir.exists()) await dir.create(recursive: true);
        path = p.join(dir.path, '$slug.xml');
        final f = File(path);
        if (!await f.exists()) {
          // 文件不存在 → 写入空模板
          await f.writeAsString(_emptyUserTemplateXml());
        }
      } else {
        return {'ok': false, 'payload': {'error': 'builtin template is read-only; duplicate first'}};
      }
      final (editor, args) = _resolveEditor(path);
      final proc = await Process.start(editor, args);
      BridgeEvents.emit('editor_opened', {'id': id, 'editor': editor, 'kind': 'template'});
      unawaited(proc.exitCode.then((code) {
        BridgeEvents.emit('file_changed', {'id': id, 'path': path, 'kind': 'template'});
      }));
      return {'ok': true, 'payload': {'editor': editor, 'path': path}};
    } catch (e) {
      return {'ok': false, 'payload': {'error': '$e'}};
    }
  }

  /// 解析编辑器命令行。
  /// 优先级:ui.editor (config.json) > $EDITOR 环境变量 > 'vi'
  /// 命令串支持以空格分隔的多段(双/单引号可保留空格),例如:
  ///   "code"               → code <path>
  ///   "code --reuse-window"→ code --reuse-window <path>
  ///   "code --goto {}"     → code --goto <path>  ({ } 占位会被 path 替换)
  /// 返回 (executable, args),可直接传给 Process.start。
  static (String, List<String>) _resolveEditor(String path) {
    String? raw;
    final ui = ConfigManager.instance.data['ui'];
    if (ui is Map && ui['editor'] is String) {
      final s = (ui['editor'] as String).trim();
      if (s.isNotEmpty) raw = s;
    }
    if (raw == null) {
      final env = Platform.environment['EDITOR'];
      if (env != null && env.trim().isNotEmpty) raw = env.trim();
    }
    raw ??= 'vi';

    final tokens = _tokenizeCmd(raw);
    if (tokens.isEmpty) tokens.add('vi');
    final exe = tokens.first;
    final rest = tokens.sublist(1);
    if (rest.any((t) => t.contains('{}'))) {
      final filled = rest.map((t) => t.replaceAll('{}', path)).toList();
      return (exe, filled);
    }
    return (exe, [...rest, path]);
  }

  /// 简单的命令行分词:空格分隔,支持双/单引号包裹的含空格字符串。
  static List<String> _tokenizeCmd(String s) {
    final out = <String>[];
    final buf = StringBuffer();
    String? quote;
    for (var i = 0; i < s.length; i++) {
      final c = s[i];
      if (quote != null) {
        if (c == quote) {
          quote = null;
        } else {
          buf.write(c);
        }
      } else if (c == '"' || c == '\'') {
        quote = c;
      } else if (c == ' ' || c == '\t') {
        if (buf.isNotEmpty) {
          out.add(buf.toString());
          buf.clear();
        }
      } else {
        buf.write(c);
      }
    }
    if (buf.isNotEmpty) out.add(buf.toString());
    return out;
  }

  static String _emptyUserTemplateXml() {
    return '''<?xml version="1.0" encoding="UTF-8"?>
<template name="新模板" description="">
<meta><max_rounds value="20"/></meta>
<system><![CDATA[
]]></system>
<tools/>
</template>
''';
  }

  /// Provider 序列化为 JSON(供 H5)。所有 model 字段由 ModelSpec.toJson 提供。
  static Map<String, dynamic> _providerToJson(ProviderSpec p) => {
        'id': p.id,
        'type': p.type,
        'base_url': p.baseUrl,
        'api_key': p.apiKey,
        'models': p.models.map((m) => m.toJson()).toList(),
      };

  /// H5 JSON → ProviderSpec(空字段容错)。model 字段由 ModelSpec.fromJson 解析。
  static ProviderSpec _providerFromJson(Map<String, dynamic> j) {
    final models = ((j['models'] as List?) ?? [])
        .map((e) => ModelSpec.fromJson(Map<String, dynamic>.from(e as Map)))
        .toList();
    return ProviderSpec(
      id: (j['id'] ?? '').toString(),
      type: (j['type'] ?? 'openai_compatible').toString(),
      baseUrl: (j['base_url'] ?? '').toString(),
      apiKey: (j['api_key'] ?? '').toString(),
      models: models,
    );
  }
}
