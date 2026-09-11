import '../session/session_model.dart';
import '../session/session_io.dart';
import 'llm_client.dart';

class TokenTracker {
  /// 写入 assistant 属性 + 累计 system 属性 + 更新 context
  static Future<void> apply(ChatSession s, Message assistantMsg, LlmUsage u) async {
    assistantMsg.input = u.input;
    assistantMsg.output = u.output;
    assistantMsg.cache = u.cacheRead + u.cacheWrite;
    s.sysInput += u.input;
    s.sysOutput += u.output;
    s.sysCache += u.cacheRead + u.cacheWrite;
    s.sysContext = u.input + u.output;
    await SessionIo.write(s);
  }
}
