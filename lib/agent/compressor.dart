import 'dart:async';

import '../config/config_manager.dart';
import '../session/session_io.dart';
import '../session/session_model.dart';
import 'llm_client.dart';
import 'token_tracker.dart';

/// 上下文压缩:
/// - 触发条件:session.system.context >= context_window * threshold
/// - 保留最近 N=3 轮(user/assistant/tool 三件套)
/// - 其余调用 summarizer model 生成 <summary>
/// - 旧 messages 整块移入 <archive summary="...">,messages 头部插入 user 摘要
/// - 重置 sys.input/output/cache/context
class Compressor {
  /// 触发阈值判定。limit 来自 config['defaults']['model_param']['context_window']
  /// 或 provider 的 model.context。
  static bool shouldCompress(ChatSession s) {
    final limit = _contextLimit(s);
    if (limit <= 0) return false;
    final threshold = s.meta.contextCompressThreshold;
    return s.sysContext >= (limit * threshold).round();
  }

  static int _contextLimit(ChatSession s) {
    // 1) 优先用 config.defaults.model_param.context_window
    final defaults = (ConfigManager.instance.data['defaults'] as Map?) ?? {};
    final mp = (defaults['model_param'] as Map?) ?? {};
    final v = (mp['context_window'] as int?) ?? 0;
    if (v > 0) return v;
    // 2) 回落到 provider 的 model.context
    final providers = (ConfigManager.instance.data['providers'] as List?) ?? [];
    for (final raw in providers) {
      final p = Map<String, dynamic>.from(raw as Map);
      if (p['id'] != s.meta.providerId) continue;
      for (final mraw in (p['models'] as List? ?? [])) {
        final m = Map<String, dynamic>.from(mraw as Map);
        if (m['id'] == s.meta.modelId) {
          return (m['context'] as int?) ?? 0;
        }
      }
    }
    return 0;
  }

  /// 入口
  static Future<bool> compress(ChatSession s, {int keepRounds = 3}) async {
    if (!shouldCompress(s)) return false;
    final all = s.messages;
    if (all.length <= keepRounds * 3) return false; // 太短不压

    // 切分:头部要压缩的,尾部 keepRounds 轮的 user/assistant/tool 三件套
    // 取最近 keepRounds 个 assistant 元素位置,所有 assistant 之后到结尾的 tool 都保留
    final assistantIdxs = <int>[];
    for (int i = 0; i < all.length; i++) {
      if (all[i].role == Role.assistant) assistantIdxs.add(i);
    }
    if (assistantIdxs.length <= keepRounds) return false;
    final cutFrom = assistantIdxs[assistantIdxs.length - keepRounds];

    final toArchive = all.sublist(0, cutFrom);
    final toKeep = all.sublist(cutFrom);

    // 生成摘要(用独立 summarizer provider/model,失败则用规则回退)
    final summary = await _summarize(s, toArchive);

    // 1) 把旧 messages 写入 archive
    s.archive = List<Message>.from(s.archive)..addAll(toArchive);
    s.archiveSummary = summary;

    // 2) messages 重置为 [user(summary), ...toKeep]
    final summaryUser = Message(role: Role.user, text: '[历史摘要]\n$summary');
    s.messages = [summaryUser, ...toKeep];

    // 3) 重置累计
    s.sysInput = 0;
    s.sysOutput = 0;
    s.sysCache = 0;
    // 上下文取最近一次 assistant 的 input/output;没有则 0
    int ctx = 0;
    for (int i = s.messages.length - 1; i >= 0; i--) {
      if (s.messages[i].role == Role.assistant && s.messages[i].input > 0) {
        ctx = s.messages[i].input + s.messages[i].output;
        break;
      }
    }
    s.sysContext = ctx;

    await SessionIo.write(s);
    return true;
  }

  /// 调 summarizer 生成一段简短摘要。
  /// summarizer 默认从 config.defaults.summarizer 读,否则退回主 provider/model。
  static Future<String> _summarize(ChatSession s, List<Message> history) async {
    if (history.isEmpty) return '';

    final defaults = (ConfigManager.instance.data['defaults'] as Map?) ?? {};
    final sum = (defaults['summarizer'] as Map?) ?? {};
    String? provId = (sum['provider_id'] as String?)?.trim();
    String? modId = (sum['model_id'] as String?)?.trim();
    provId = (provId != null && provId.isNotEmpty) ? provId : s.meta.providerId;
    modId = (modId != null && modId.isNotEmpty) ? modId : s.meta.modelId;
    if (provId == null || provId.isEmpty) {
      return _fallbackSummary(history);
    }

    // 构造 summarizer 用的临时 session
    final tmp = ChatSession(
      id: 'summarizer',
      sandbox: s.sandbox,
      meta: ChatMeta(
        providerId: provId,
        modelId: modId,
        temperature: 0.2,
      ),
      systemPrompt: '你是摘要助手。把以下对话历史压缩为 200 字内的中文摘要,保留关键事实、决策、文件路径、错误。不要遗漏数字与标识符。',
    );

    // 把 history 转 messages(只取 user/assistant,tool 折到 assistant 文本里)
    final msgs = <Map<String, dynamic>>[];
    msgs.add({'role': 'system', 'content': tmp.systemPrompt});
    String assistantBuf = '';
    for (final m in history) {
      if (m.role == Role.user) {
        if (assistantBuf.isNotEmpty) {
          msgs.add({'role': 'assistant', 'content': assistantBuf});
          assistantBuf = '';
        }
        msgs.add({'role': 'user', 'content': m.text});
      } else if (m.role == Role.assistant) {
        assistantBuf = m.text;
      } else if (m.role == Role.tool) {
        assistantBuf += '\n[tool ${m.toolName}] ${m.text}';
      }
    }
    if (assistantBuf.isNotEmpty) {
      msgs.add({'role': 'assistant', 'content': assistantBuf});
    }
    msgs.add({'role': 'user', 'content': '请基于以上对话输出摘要。'});

    try {
      final resp = await LlmClient.call(
        session: tmp,
        messages: msgs,
        onChunk: (_) {},
      );
      if (resp.text.startsWith('ERROR:') || resp.text.trim().isEmpty) {
        return _fallbackSummary(history);
      }
      // 累计这次 summarizer 的 usage 进主 session
      final fakeMsg = Message(role: Role.assistant, text: resp.text, model: resp.model);
      await TokenTracker.apply(s, fakeMsg, resp.usage);
      return resp.text.trim();
    } catch (_) {
      return _fallbackSummary(history);
    }
  }

  /// 规则回退:取前 N 个 user 文本 + 第一个 assistant 文本拼接。
  static String _fallbackSummary(List<Message> history) {
    final users = history.where((m) => m.role == Role.user).take(5).map((m) => m.text);
    final firstAssistant = history
        .firstWhere((m) => m.role == Role.assistant, orElse: () => Message(role: Role.assistant, text: ''))
        .text;
    final buf = StringBuffer();
    buf.writeln('历史要点:');
    for (final u in users) {
      buf.writeln('- ${u.length > 200 ? u.substring(0, 200) + '…' : u}');
    }
    if (firstAssistant.isNotEmpty) {
      buf.writeln('首条回复: ${firstAssistant.length > 300 ? firstAssistant.substring(0, 300) + '…' : firstAssistant}');
    }
    return buf.toString();
  }
}
