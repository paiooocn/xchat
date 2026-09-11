import 'dart:convert';

/// OpenAI Chat Completions 协议校验器。
///
/// 校验内容(发送前):
/// - messages 数组非空
/// - 第一条必须是 system 或 user
/// - 每条 message 必须有 role,且 role ∈ {system,user,assistant,tool}
/// - user/assistant/system:content 必须是 String(可空字符串)
/// - tool:必须有 tool_call_id(String)、content(String);name 可选
/// - assistant 含 tool_calls 时:
///     - tool_calls 数组非空
///     - 每条 tc 必须有 id(String)、type='function'、function.name(String)、function.arguments(必须是 JSON String)
/// - assistant 不含 tool_calls 时:必须有 content(String,允许空)
/// - 配对校验:assistant{tool_calls[i].id} 必须有紧随其后的 tool{tool_call_id == id}
class OpenAiValidator {
  /// 校验失败时返回错误信息;成功返回 null。
  static String? validate(List<Map<String, dynamic>> messages) {
    if (messages.isEmpty) return 'messages array is empty';

    final first = messages.first;
    final firstRole = first['role'];
    if (firstRole != 'system' && firstRole != 'user') {
      return 'first message role must be system or user, got $firstRole';
    }

    // 每条消息基础校验
    for (var i = 0; i < messages.length; i++) {
      final m = messages[i];
      final err = _validateOne(m, i);
      if (err != null) return err;
    }

    // 配对校验:assistant{tool_calls[i].id} 必须有紧随其后的 tool{tool_call_id == id}
    final pendingIds = <String>[];
    for (var i = 0; i < messages.length; i++) {
      final m = messages[i];
      if (m['role'] == 'assistant' && m['tool_calls'] is List) {
        for (final tc in (m['tool_calls'] as List)) {
          if (tc is Map && tc['id'] is String) {
            pendingIds.add(tc['id'] as String);
          }
        }
      } else if (m['role'] == 'tool') {
        final id = m['tool_call_id'];
        if (id is! String || id.isEmpty) {
          return 'tool message at index $i missing tool_call_id';
        }
        if (pendingIds.isEmpty) {
          return 'orphan tool message at index $i (no preceding assistant.tool_calls), tool_call_id=$id';
        }
        if (!pendingIds.remove(id)) {
          return 'tool message at index $i has tool_call_id=$id not matching any pending call (pending=$pendingIds)';
        }
      } else {
        // 非 tool 消息:如果有 pending tool_calls 未消费,说明 assistant 后没接对应 tool 结果
        if (pendingIds.isNotEmpty) {
          return 'unconsumed assistant tool_calls before index $i; pending=$pendingIds';
        }
      }
    }
    if (pendingIds.isNotEmpty) {
      return 'unconsumed assistant tool_calls at end of messages; pending=$pendingIds';
    }
    return null;
  }

  static String? _validateOne(Map<String, dynamic> m, int i) {
    final role = m['role'];
    if (role is! String) return 'message[$i] missing role';
    switch (role) {
      case 'system':
      case 'user':
        final c = m['content'];
        if (c is! String && c != null) {
          return 'message[$i] role=$role content must be string or null';
        }
        break;
      case 'assistant':
        final hasTcs = m['tool_calls'] is List && (m['tool_calls'] as List).isNotEmpty;
        if (hasTcs) {
          final tcs = m['tool_calls'] as List;
          for (var k = 0; k < tcs.length; k++) {
            final tc = tcs[k];
            if (tc is! Map) return 'message[$i].tool_calls[$k] must be object';
            if (tc['id'] is! String || (tc['id'] as String).isEmpty) {
              return 'message[$i].tool_calls[$k] missing string id';
            }
            if (tc['type'] != 'function') {
              return 'message[$i].tool_calls[$k].type must be "function"';
            }
            final fn = tc['function'];
            if (fn is! Map) return 'message[$i].tool_calls[$k].function must be object';
            if (fn['name'] is! String || (fn['name'] as String).isEmpty) {
              return 'message[$i].tool_calls[$k].function.name missing';
            }
            final args = fn['arguments'];
            if (args is! String) {
              return 'message[$i].tool_calls[$k].function.arguments must be JSON string, got ${args.runtimeType}';
            }
            try {
              jsonDecode(args);
            } catch (e) {
              return 'message[$i].tool_calls[$k].function.arguments not valid JSON: $e';
            }
          }
        } else {
          final c = m['content'];
          if (c is! String) {
            return 'message[$i] assistant without tool_calls must have string content';
          }
        }
        break;
      case 'tool':
        final id = m['tool_call_id'];
        if (id is! String || id.isEmpty) {
          return 'message[$i] tool missing tool_call_id';
        }
        final c = m['content'];
        if (c is! String) return 'message[$i] tool content must be string';
        break;
      default:
        return 'message[$i] unknown role "$role"';
    }
    return null;
  }

  /// 一次性规范化:把 assistant 含 tool_calls 且 text 为空的 content 从 null 改为空字符串。
  /// 多数 OpenAI 兼容服务在 stream=true 时接受 null,但部分实现会报 400,
  /// 这里统一改成 '' 以最大化兼容性。
  static List<Map<String, dynamic>> normalize(List<Map<String, dynamic>> messages) {
    return messages.map((m) {
      if (m['role'] == 'assistant' && m['tool_calls'] is List && (m['tool_calls'] as List).isNotEmpty) {
        final out = Map<String, dynamic>.from(m);
        if (out['content'] == null) out['content'] = '';
        return out;
      }
      return m;
    }).toList();
  }
}
