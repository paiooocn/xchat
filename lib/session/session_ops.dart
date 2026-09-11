import '../util/uuid.dart';
import 'session_io.dart';
import 'session_model.dart';

class SessionOps {
  /// 克隆到第一个 <user> 之前（保留全部历史）
  static Future<ChatSession> cloneFull(String id) async {
    final s = await SessionIo.read(id);
    s.id = uuidV4();
    s.created = DateTime.now().toUtc();
    s.updated = DateTime.now().toUtc();
    s.title = '${s.title ?? "(克隆)"} (副本)';
    await SessionIo.write(s);
    return s;
  }

  /// 克隆空会话（仅 meta + system + tools + 项目/标签）。
  /// 不复制 messages/archive;新 id 重新生成。
  /// [titleSuffix] 追加到原 title 后(默认 " (空副本)")。
  /// 注意:本方法不写盘,调用方负责 SessionIo.write 落盘。
  static Future<ChatSession> cloneEmpty(String id, {String? titleSuffix}) async {
    final s = await SessionIo.read(id);
    final suffix = titleSuffix ?? ' (空副本)';
    return ChatSession(
      id: uuidV4(),
      sandbox: s.sandbox,
      title: s.title == null ? null : '${s.title}$suffix',
      created: DateTime.now().toUtc(),
      updated: DateTime.now().toUtc(),
      maxRounds: s.maxRounds,
      meta: s.meta,
      systemPrompt: s.systemPrompt,
      tools: s.tools.map((t) => ToolDef(t.name, enabled: t.enabled)).toList(),
      projectId: s.projectId,
      tags: List<String>.from(s.tags),
    );
  }

  /// 重发会话：截断到最后 user 为止，替换为新文本
  static Future<ChatSession> resend(String id, String newUserText) async {
    final s = await SessionIo.read(id);
    // 找最后一个 user 索引
    int lastUserIdx = -1;
    for (int i = s.messages.length - 1; i >= 0; i--) {
      if (s.messages[i].role == Role.user) {
        lastUserIdx = i;
        break;
      }
    }
    if (lastUserIdx < 0) {
      // 无 user，直接追加
      s.messages.add(Message(role: Role.user, text: newUserText));
    } else {
      s.messages[lastUserIdx] = Message(role: Role.user, text: newUserText);
      // 截断该 user 之后的所有消息
      s.messages = s.messages.sublist(0, lastUserIdx + 1);
    }
    s.updated = DateTime.now().toUtc();
    await SessionIo.write(s);
    return s;
  }
}
