import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;

import '../config/config_manager.dart';
import '../session/session_model.dart';

class LlmUsage {
  final int input;
  final int output;
  final int cacheRead;
  final int cacheWrite;
  LlmUsage(this.input, this.output, this.cacheRead, this.cacheWrite);
  static LlmUsage zero() => LlmUsage(0, 0, 0, 0);
}

class LlmResponse {
  final String text;
  final List<ToolCall> toolCalls;
  final LlmUsage usage;
  final String? model;
  LlmResponse(this.text, this.toolCalls, this.usage, {this.model});
}

/// 通用 LLM 适配：openai_compatible + anthropic
class LlmClient {
  /// 流式调 LLM；onChunk 每次文本增量
  static Future<LlmResponse> call({
    required ChatSession session,
    required List<Map<String, dynamic>> messages,
    required void Function(String delta) onChunk,
  }) async {
    final config = ConfigManager.instance.data;
    final providers = (config['providers'] as List?) ?? [];
    final providerId = session.meta.providerId;
    final modelId = session.meta.modelId;
    Map? provider;
    for (final p in providers) {
      if ((p as Map)['id'] == providerId) {
        provider = p;
        break;
      }
    }
    if (provider == null) {
      return LlmResponse('ERROR: provider $providerId not configured', [], LlmUsage.zero());
    }
    final type = provider['type'] ?? 'openai_compatible';
    if (type == 'anthropic') {
      return _callAnthropic(provider, modelId, session, messages, onChunk);
    }
    return _callOpenAI(provider, modelId, session, messages, onChunk);
  }

  // -------- openai_compatible --------
  static Future<LlmResponse> _callOpenAI(
    Map provider,
    String? modelId,
    ChatSession session,
    List<Map<String, dynamic>> messages,
    void Function(String delta) onChunk,
  ) async {
    final baseUrl = provider['base_url'] ?? '';
    final apiKey = provider['api_key'] ?? '';
    final tools = session.tools
        .where((t) => t.enabled)
        .map((t) => {'type': 'function', 'function': _openAIToolSchema(t.name)})
        .toList();

    // 模型级可选参数(从 provider.models 查表;未配置时回落到 session.meta)
    final modelOpts = _modelOptionsFor(provider, modelId);
    final thinking = (modelOpts.thinking ?? session.meta.thinking).trim();
    final reasoningEffortRaw = (modelOpts.reasoningEffort ?? session.meta.reasoningEffort).trim();
    final temperatureRaw = modelOpts.temperature ?? session.meta.temperature;
    final temperature = temperatureRaw.clamp(0.0, 2.0).toDouble();
    final hasTemperature = thinking != 'enabled' || _isOpenAiThinkingFake(thinking);
    // OpenAI 协议: temperature 与 reasoning_effort 互斥;若 thinking 强行启用则忽略 reasoning_effort

    final body = <String, dynamic>{
      'model': modelId,
      'messages': messages,
      'stream': true,
      'stream_options': {'include_usage': true},
      if (tools.isNotEmpty) 'tools': tools,
    };
    if (hasTemperature) {
      body['temperature'] = temperature;
    }
    // reasoning_effort: 非空且非 '--' 时下发
    if (reasoningEffortRaw.isNotEmpty && reasoningEffortRaw != '--') {
      body['reasoning_effort'] = reasoningEffortRaw;
    }
    // thinking: OpenAI 协议无原生字段;
    // - 'enabled'  -> 视为 high 级别推理(下发 reasoning_effort=high)
    // - 'adaptive' -> 透传 reasoning_effort 字段(由服务端解释)
    // - 'disabled' 或 '--' -> 不下发 thinking 相关字段
    if (thinking == 'enabled' && !body.containsKey('reasoning_effort')) {
      body['reasoning_effort'] = 'high';
    }

    final req = http.Request('POST', Uri.parse('$baseUrl/chat/completions'));
    req.headers['Content-Type'] = 'application/json';
    if (apiKey.isNotEmpty) req.headers['Authorization'] = 'Bearer $apiKey';
    req.body = jsonEncode(body);

    final resp = await req.send();
    if (resp.statusCode != 200) {
      final err = await resp.stream.bytesToString();
      final errText = 'ERROR: HTTP ${resp.statusCode} $err';
      return LlmResponse(errText, [], LlmUsage.zero());
    }

    final textBuf = StringBuffer();
    final toolCallsRaw = <Map<String, dynamic>>[];
    int input = 0, output = 0, cacheRead = 0;

    // 修复 #2: 部分 OpenAI 兼容服务(尤其带 keepalive 的代理)发完文本后不送
    // [DONE] 且不关连接,await for 会无限等下去。ReactLoop 主循环的 try/catch
    // 也接不到(没有异常),前端永远收不到 done/error → 输入框永久 disabled。
    // 这里给 stream 加 60s 超时保护:超时后抛 TimeoutException,我们在 catch 中
    // 返回 ERROR: stream_timeout_60s,触发 ReactLoop 的终止事件。
    final rawLines = resp.stream.transform(utf8.decoder).transform(const LineSplitter());
    final lines = rawLines.timeout(const Duration(seconds: 60));
    try {
      await for (final line in lines) {
        if (!line.startsWith('data: ')) continue;
        final data = line.substring(6).trim();
        if (data == '[DONE]') break;
        Map<String, dynamic>? j;
        try {
          j = jsonDecode(data) as Map<String, dynamic>;
        } catch (e) {
          // ignore: avoid_print
          print('[XChat][llm_client] OpenAI stream JSON parse error: $e data=${data.length > 200 ? data.substring(0, 200) + "..." : data}');
          continue;
        }
        final choice = (j['choices'] as List?)?.firstOrNull;
        if (choice is Map) {
          final delta = choice['delta'] as Map?;
          if (delta != null) {
            final content = delta['content'];
            if (content is String && content.isNotEmpty) {
              textBuf.write(content);
              onChunk(content);
            }
            final tcs = delta['tool_calls'];
            if (tcs is List) {
              for (final raw in tcs) {
                if (raw is Map) {
                  final idx = raw['index'] ?? 0;
                  while (toolCallsRaw.length <= idx) {
                    toolCallsRaw.add({'id': '', 'name': '', 'arguments': ''});
                  }
                  final tgt = toolCallsRaw[idx];
                  if (raw['id'] is String) tgt['id'] = raw['id'];
                  final fn = raw['function'];
                  if (fn is Map) {
                    if (fn['name'] is String) tgt['name'] = (tgt['name'] as String) + fn['name'];
                    if (fn['arguments'] is String) tgt['arguments'] = (tgt['arguments'] as String) + fn['arguments'];
                  }
                }
              }
            }
          }
        }
        final usage = j['usage'];
        if (usage is Map) {
          input = (usage['prompt_tokens'] as int?) ?? input;
          output = (usage['completion_tokens'] as int?) ?? output;
          final details = usage['prompt_tokens_details'];
          if (details is Map) {
            cacheRead = (details['cached_tokens'] as int?) ?? cacheRead;
          }
        }
      }
    } on TimeoutException {
      // ignore: avoid_print
      print('[XChat][llm_client] OpenAI stream timeout (60s) model=$modelId url=$baseUrl/chat/completions');
      return LlmResponse('ERROR: stream_timeout_60s', [], LlmUsage.zero(), model: modelId);
    }

    final tcs = toolCallsRaw
        .where((t) => (t['name'] as String).isNotEmpty)
        .map((t) => ToolCall(
              id: t['id'] as String,
              name: t['name'] as String,
              arguments: (t['arguments'] as String).isEmpty ? '{}' : t['arguments'] as String,
            ))
        .toList();

    return LlmResponse(textBuf.toString(), tcs, LlmUsage(input, output, cacheRead, 0), model: modelId);
  }

  static Map<String, dynamic> _openAIToolSchema(String name) {
    final schemas = <String, Map<String, dynamic>>{
      'read_file': {
        'name': 'read_file',
        'description': '读取文件',
        'parameters': {
          'type': 'object',
          'properties': {'path': {'type': 'string'}},
          'required': ['path'],
        },
      },
      'write_file': {
        'name': 'write_file',
        'description': '写入文件',
        'parameters': {
          'type': 'object',
          'properties': {
            'path': {'type': 'string'},
            'content': {'type': 'string'},
          },
          'required': ['path', 'content'],
        },
      },
      'edit_file': {
        'name': 'edit_file',
        'description': '编辑文件',
        'parameters': {
          'type': 'object',
          'properties': {
            'path': {'type': 'string'},
            'find': {'type': 'string'},
            'replace': {'type': 'string'},
            'all_occurrences': {'type': 'boolean'},
          },
          'required': ['path', 'find', 'replace'],
        },
      },
      'list_dir': {
        'name': 'list_dir',
        'description': '列目录',
        'parameters': {
          'type': 'object',
          'properties': {'path': {'type': 'string'}},
        },
      },
      'glob': {
        'name': 'glob',
        'description': 'glob 匹配',
        'parameters': {
          'type': 'object',
          'properties': {'pattern': {'type': 'string'}},
          'required': ['pattern'],
        },
      },
      'grep': {
        'name': 'grep',
        'description': '正则搜索',
        'parameters': {
          'type': 'object',
          'properties': {
            'pattern': {'type': 'string'},
            'path': {'type': 'string'},
            'ignore_case': {'type': 'boolean'},
          },
          'required': ['pattern'],
        },
      },
      'shell': {
        'name': 'shell',
        'description': '执行 shell 命令（cwd=sandbox）',
        'parameters': {
          'type': 'object',
          'properties': {'cmd': {'type': 'string'}},
          'required': ['cmd'],
        },
      },
      'get_time': {
        'name': 'get_time',
        'description': '当前 UTC 时间',
        'parameters': {'type': 'object', 'properties': {}},
      },
    };
    return schemas[name] ?? {'name': name, 'parameters': {'type': 'object', 'properties': {}}};
  }

  static String _mapReasoningEffort(String v) {
    const map = {
      'max': 'high',
      'xhigh': 'high',
      'high': 'high',
      'medium': 'medium',
      'low': 'low',
      'minimal': 'minimal',
      'none': 'low',
    };
    return map[v] ?? 'medium';
  }

  /// OpenAI 协议是否需要把 thinking 当成 fake reasoning_effort。
  /// 实际 OpenAI 没有 thinking 字段,这里仅给上层一个 hook,目前统一按 false 走。
  static bool _isOpenAiThinkingFake(String thinking) => false;

  /// 在 provider.models 里查指定 modelId 的可选参数。
  /// 找不到时返回全部为空的 ModelSpec(用空 thinking/-- reasoningEffort 等占位)。
  static _ModelOptions _modelOptionsFor(Map provider, String? modelId) {
    final models = (provider['models'] as List?) ?? [];
    for (final raw in models) {
      if (raw is Map && raw['id'] == modelId) {
        return _ModelOptions(
          thinking: (raw['thinking'] as String?)?.trim(),
          reasoningEffort: (raw['reasoning_effort'] as String?)?.trim(),
          temperature: (raw['temperature'] as num?)?.toDouble(),
        );
      }
    }
    return const _ModelOptions();
  }

  // -------- anthropic --------
  static Future<LlmResponse> _callAnthropic(
    Map provider,
    String? modelId,
    ChatSession session,
    List<Map<String, dynamic>> messages,
    void Function(String delta) onChunk,
  ) async {
    final baseUrl = provider['base_url'] ?? '';
    final apiKey = provider['api_key'] ?? '';

    // 拆分 system 与非 system
    String sys = session.systemPrompt;
    final msgs = <Map<String, dynamic>>[];
    for (final m in messages) {
      if (m['role'] == 'system') {
        sys += '\n' + (m['content'] as String);
      } else {
        msgs.add(m);
      }
    }

    final tools = session.tools.where((t) => t.enabled).map((t) {
      final s = _openAIToolSchema(t.name);
      return {
        'name': t.name,
        'description': s['description'],
        'input_schema': s['parameters'],
      };
    }).toList();

    // 模型级可选参数(回落到 session.meta)
    final modelOpts = _modelOptionsFor(provider, modelId);
    final thinking = (modelOpts.thinking ?? session.meta.thinking).trim();
    final temperatureRaw = modelOpts.temperature ?? session.meta.temperature;
    final temperature = temperatureRaw.clamp(0.0, 2.0).toDouble();

    // Anthropic 协议:thinking 启用时禁止同时下发 temperature
    final thinkingEnabled = thinking == 'enabled';
    final budgetTokens = 4096;
    final body = <String, dynamic>{
      'model': modelId,
      'system': sys,
      'messages': msgs,
      'max_tokens': thinkingEnabled ? budgetTokens + 4096 : 4096,
      'stream': true,
      if (tools.isNotEmpty) 'tools': tools,
    };
    if (!thinkingEnabled) {
      body['temperature'] = temperature;
    }
    if (thinking == 'enabled') {
      body['thinking'] = {'type': 'enabled', 'budget_tokens': budgetTokens};
    } else if (thinking == 'disabled' || thinking == 'adaptive' || thinking == '--' || thinking.isEmpty) {
      // 不下发 thinking 块,沿用服务端默认
    }

    final req = http.Request('POST', Uri.parse('$baseUrl/v1/messages'));
    req.headers['Content-Type'] = 'application/json';
    req.headers['x-api-key'] = apiKey;
    req.headers['anthropic-version'] = '2023-06-01';
    req.body = jsonEncode(body);

    final resp = await req.send();
    if (resp.statusCode != 200) {
      final err = await resp.stream.bytesToString();
      // ignore: avoid_print
      print('[XChat][llm_client] Anthropic HTTP ${resp.statusCode} url=$baseUrl/v1/messages model=$modelId body=${err.length > 500 ? err.substring(0, 500) + "..." : err}');
      final errText = 'ERROR: HTTP ${resp.statusCode} $err';
      return LlmResponse(errText, [], LlmUsage.zero());
    }

    final textBuf = StringBuffer();
    final toolCallsRaw = <Map<String, dynamic>>[];
    int input = 0, output = 0, cacheRead = 0, cacheWrite = 0;
    String currentToolId = '';
    String currentToolName = '';
    String currentToolInput = '';

    // 修复 #2: 与 _callOpenAI 一致,Anthropic SSE 也加 60s 超时保护,
    // 防止服务端 keepalive / 中断半关连接导致 await for 永久等待。
    final rawLines = resp.stream.transform(utf8.decoder).transform(const LineSplitter());
    final lines = rawLines.timeout(const Duration(seconds: 60));
    try {
      await for (final line in lines) {
        if (!line.startsWith('data: ')) continue;
        final data = line.substring(6).trim();
        if (data.isEmpty) continue;
      Map<String, dynamic>? j;
      try {
        j = jsonDecode(data) as Map<String, dynamic>;
      } catch (e) {
        // ignore: avoid_print
        print('[XChat][llm_client] Anthropic stream JSON parse error: $e data=${data.length > 200 ? data.substring(0, 200) + "..." : data}');
        continue;
      }
      final type = j['type'];
      if (type == 'content_block_start') {
        final block = j['content_block'];
        if (block is Map && block['type'] == 'tool_use') {
          currentToolId = block['id'] ?? '';
          currentToolName = block['name'] ?? '';
          currentToolInput = '';
        }
      } else if (type == 'content_block_delta') {
        final delta = j['delta'];
        if (delta is Map) {
          if (delta['type'] == 'text_delta') {
            final t = delta['text'] ?? '';
            textBuf.write(t);
            onChunk(t);
          } else if (delta['type'] == 'input_json_delta') {
            currentToolInput += (delta['partial_json'] ?? '');
          }
        }
      } else if (type == 'content_block_stop') {
        if (currentToolName.isNotEmpty) {
          toolCallsRaw.add({
            'id': currentToolId,
            'name': currentToolName,
            'arguments': currentToolInput.isEmpty ? '{}' : currentToolInput,
          });
          currentToolId = '';
          currentToolName = '';
          currentToolInput = '';
        }
      } else if (type == 'message_delta') {
        final usage = j['usage'];
        if (usage is Map) {
          output = (usage['output_tokens'] as int?) ?? output;
        }
      } else if (type == 'message_start') {
        final msg = j['message'];
        if (msg is Map) {
          final usage = msg['usage'];
          if (usage is Map) {
            input = (usage['input_tokens'] as int?) ?? input;
            cacheRead = (usage['cache_read_input_tokens'] as int?) ?? cacheRead;
            cacheWrite = (usage['cache_creation_input_tokens'] as int?) ?? cacheWrite;
          }
        }
      }
    }
    } on TimeoutException {
      // ignore: avoid_print
      print('[XChat][llm_client] Anthropic stream timeout (60s) model=$modelId url=$baseUrl/v1/messages');
      return LlmResponse('ERROR: stream_timeout_60s', [], LlmUsage.zero(), model: modelId);
    }

    final tcs = toolCallsRaw
        .map((t) => ToolCall(
              id: t['id'] as String,
              name: t['name'] as String,
              arguments: t['arguments'] as String,
            ))
        .toList();

    return LlmResponse(textBuf.toString(), tcs, LlmUsage(input, output, cacheRead, cacheWrite), model: modelId);
  }
}

/// 内部承载 provider.model 单条记录的 3 个可选参数。
/// 三者都允许为 null,表示"模型未显式配置,回落到 session.meta / ChatMeta() 默认值"。
class _ModelOptions {
  final String? thinking;
  final String? reasoningEffort;
  final double? temperature;
  const _ModelOptions({this.thinking, this.reasoningEffort, this.temperature});
}

extension on List {
  dynamic get firstOrNull => isEmpty ? null : first;
}
