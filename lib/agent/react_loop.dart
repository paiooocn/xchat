import 'dart:async';
import 'dart:convert';

import '../bridge/bridge_events.dart';
import '../config/config_manager.dart';
import '../session/session_io.dart';
import '../session/session_model.dart';
import '../tools/tool_registry.dart';
import '../util/uuid.dart';
import 'compressor.dart';
import 'llm_client.dart';
import 'openai_validator.dart';
import 'run_result.dart';
import 'token_tracker.dart';

class ReactLoop {
  static bool _stopRequested = false;
  static void stop() => _stopRequested = true;

  /// 仅按 id 启动 run,内部 read session;读失败时立刻 emit error 让前端 setRunning(false)。
  /// 用于 bridge_api.chat.send: 之前 chat.send 自己 await SessionIo.read(sid),
  /// IO hang 时 RPC 永不返回 + 前端 input.value 已清空 + setRunning(true) 永远等不到,
  /// 表现即"卡死"。
  static Future<void> runById(String sessionId, String userText) async {
    ChatSession s;
    try {
      s = await SessionIo.read(sessionId);
    } catch (e) {
      // ignore: avoid_print
      print('[XChat][react_loop] failed to read session $sessionId: $e');
      BridgeEvents.emit('error', {'sessionId': sessionId, 'message': 'session_read_failed: $e'});
      return;
    }
    try {
      await run(s, userText);
    } catch (e, st) {
      // ignore: avoid_print
      print('[XChat][react_loop] run() threw unhandled (session=$sessionId): $e\n$st');
      BridgeEvents.emit('error', {'sessionId': sessionId, 'message': '$e'});
    }
  }

  /// 主入口
  static Future<RunResult> run(ChatSession session, String userText) async {
    _stopRequested = false;
    final s = session;

    // 追加 user
    // 修复 #1: 头三行(尤其是 SessionIo.write)历史上在 try 外,磁盘满/权限/IO 错
    // 抛出的异常会绕过整段 try/catch,直接变成 Dart 未处理 Future 错误,
    // 前端永远收不到 error/done,输入框永久 disabled。这里把整段初始写入包进
    // try/catch,失败时强制 emit error 让前端 setRunning(false)。
    try {
      s.messages.add(Message(role: Role.user, text: userText));
      await SessionIo.write(s);
      BridgeEvents.emit('user_appended', {'sessionId': s.id, 'text': userText});
    } catch (e, st) {
      // ignore: avoid_print
      print('[XChat][react_loop] failed to append user message (session=${s.id}): $e\n$st');
      BridgeEvents.emit('error', {'sessionId': s.id, 'message': 'append_user_failed: $e'});
      return RunResult(RunKind.error, message: 'append_user_failed: $e');
    }

    int roundCount = 0;
    bool needsContinue = false;

    try {
    while (true) {
      if (_stopRequested) {
        BridgeEvents.emit('stopped', {'sessionId': s.id});
        return RunResult(RunKind.done, message: 'stopped');
      }

      if (needsContinue) {
        s.messages.add(Message(
          role: Role.user,
          text: '[续会话] 上一会话因 max_rounds=${s.maxRounds} 中断，从此处继续。',
        ));
        await SessionIo.write(s);
        needsContinue = false;
      }

      // 拼 messages
      final msgs = _buildMessages(s);
      // 规范化:assistant{tool_calls} 的 content 若是 null,统一改为 '' (部分 OpenAI 兼容服务拒收 null)
      final normalized = OpenAiValidator.normalize(msgs);

      // 发送前 OpenAI 协议校验;失败打印并把错误信息回填到 assistant,立即终止
      final vErr = OpenAiValidator.validate(normalized);
      if (vErr != null) {
        // ignore: avoid_print
        print('[XChat][react_loop] OpenAI protocol validation failed (session=${s.id}, round=$roundCount): $vErr');
        final errText = 'ERROR: protocol_validation: $vErr';
        final errMsg = Message(role: Role.assistant, text: errText);
        s.messages.add(errMsg);
        await SessionIo.write(s);
        BridgeEvents.emit('assistant_done', {'sessionId': s.id, 'text': errText, 'tool_calls': []});
        // 修复:必须发终止事件,前端 setRunning(false) 才有机会触发,否则输入框一直 disabled
        BridgeEvents.emit('error', {'sessionId': s.id, 'message': errText});
        return RunResult(RunKind.error, message: errText);
      }

      // 流式调 LLM: chunk 通过事件直接推送,主入口只 await 终态。
      // 修复: 旧实现 onChunk 内尝试 complete(captured) 会因 captured 还未赋值
      // 而永真等待。这里删掉 onChunk 内的 complete 逻辑。
      final resp = await LlmClient.call(
        session: s,
        messages: normalized,
        onChunk: (delta) {
          BridgeEvents.emit('chunk', {'sessionId': s.id, 'delta': delta});
        },
      );

      if (resp.text.startsWith('ERROR:')) {
        // ignore: avoid_print
        print('[XChat][react_loop] LLM API error (session=${s.id}, round=$roundCount): ${resp.text}');
      }

      // 写 assistant
      final assistantMsg = Message(
        role: Role.assistant,
        text: resp.text,
        toolCalls: resp.toolCalls,
        model: resp.model,
      );
      assistantMsg.input = resp.usage.input;
      assistantMsg.output = resp.usage.output;
      assistantMsg.cache = resp.usage.cacheRead + resp.usage.cacheWrite;
      s.messages.add(assistantMsg);

      BridgeEvents.emit('assistant_done', {
        'sessionId': s.id,
        'text': resp.text,
        'tool_calls': resp.toolCalls.map((c) => {'id': c.id, 'name': c.name, 'arguments': c.arguments}).toList(),
        // 修复:把这一轮的 in/out/cache 一起带上,前端无需依赖落盘后回读
        // 即可把消息元数据对齐到真实用量(否则前端 streaming 节点停留在 0,
        // 用户必须关闭并重开会话才看得到)。
        'input': resp.usage.input,
        'output': resp.usage.output,
        'cache': resp.usage.cacheRead + resp.usage.cacheWrite,
      });

      // 修复 #3: TokenTracker.apply 走 file.writeAsString(flush: true) 同步写盘,
      // 历史上有过被杀毒软件实时扫描/外力打断等场景下卡秒级到分钟级的记录,
      // 期间前端 UI 仍然 disabled 表现为卡死。这里改成 fire-and-forget,
      // 不阻塞主循环;数据最终会落盘,异常由自身 try/catch 吞掉不污染主调用栈。
      // 忽略 lint:fire-and-forget Future 在 ReactLoop.run 主流程里安全。
      // ignore: unawaited_futures
      () async {
        try {
          await TokenTracker.apply(s, assistantMsg, resp.usage);
        } catch (e) {
          // ignore: avoid_print
          print('[XChat][react_loop] TokenTracker.apply failed (session=${s.id}): $e');
        }
      }();

      // 上下文压缩:每轮结束后判定
      if (Compressor.shouldCompress(s)) {
        final before = s.messages.length;
        final ok = await Compressor.compress(s);
        if (ok) {
          BridgeEvents.emit('compressed', {
            'sessionId': s.id,
            'archivedCount': before - s.messages.length,
            'summary': s.archiveSummary ?? '',
          });
        }
      }

      if (resp.text.startsWith('ERROR:')) {
        // 修复:同上,必须发终止事件让前端解除 disabled 状态
        BridgeEvents.emit('error', {'sessionId': s.id, 'message': resp.text});
        return RunResult(RunKind.error, message: resp.text);
      }

      // 多轮连续性检查: 仅在有 tool 结果历史(说明这是第 2+ 轮 LLM 调用)时,
      // 如果 LLM 突然给纯文本且没有调用过任何工具,理论上也合法——所以这里只打日志,
      // 不强制继续。
      if (resp.toolCalls.isEmpty) {
        // ignore: avoid_print
        print('[XChat][react_loop] LLM finished turn (session=${s.id}, round=$roundCount, finalLen=${resp.text.length})');
        BridgeEvents.emit('done', {'sessionId': s.id, 'finalText': resp.text});
        return RunResult(RunKind.done, message: resp.text);
      }

      // 准备进入下一轮:把本轮 assistant 的 tool_calls id 记录下来,后续 tool 消息必须对齐
      final expectedToolIds = resp.toolCalls.map((c) => c.id).toSet();
      // ignore: avoid_print
      print('[XChat][react_loop] LLM requested ${resp.toolCalls.length} tool call(s) (session=${s.id}, round=$roundCount, ids=$expectedToolIds)');

      // 执行工具
      for (final call in resp.toolCalls) {
        if (_stopRequested) break;

        BridgeEvents.emit('tool_start', {
          'sessionId': s.id,
          'callId': call.id,
          'name': call.name,
          'arguments': call.arguments,
        });

        Map<String, dynamic> args;
        try {
          args = jsonDecode(call.arguments) as Map<String, dynamic>;
        } catch (_) {
          args = {};
        }

        // 检查 confirm
        final mode = s.meta.confirmMode ??
            (ConfigManager.instance.data['ui']?['confirm_mode'] ?? 'normal') as String;

        if (ToolRegistry.shouldConfirm(call.name, mode)) {
          // 推 confirm_required(桥接层会等待用户决定)
          final decision = await BridgeEvents.waitForConfirm(s.id, call.id);
          if (!decision['allow']) {
            s.messages.add(Message(
              role: Role.tool,
              text: 'ERROR: user_denied',
              toolCallId: call.id,
              toolName: call.name,
            ));
            await SessionIo.write(s);
            continue;
          }
        }

        // 执行(异常上抛以触发 layer_a 中止)
        String result;
        try {
          result = ToolRegistry.execute(
            call.name,
            s.sandbox,
            args,
            confirmMode: mode,
            alreadyConfirmed: true,
          );
          if (result.startsWith('ERROR:')) {
            // ignore: avoid_print
            print('[XChat][react_loop] tool exec error (session=${s.id}, call=${call.name}, id=${call.id}): $result');
          }
          // blocked_layer_a / blocked_exception_yolo 在 ToolRegistry.execute 内部
          // 已经 throw BlockedLayerA/BlockedExceptionYolo,下面的 on-catch 会接住。
        } on BlockedLayerA catch (e) {
          s.messages.add(Message(
            role: Role.tool,
            text: 'ERROR: $e',
            toolCallId: call.id,
            toolName: call.name,
          ));
          await SessionIo.write(s);
          BridgeEvents.emit('blocked_layer_a', {
            'sessionId': s.id,
            'callId': call.id,
            'cmd': args['cmd'] ?? '',
            'message': e.toString(),
          });
          // ignore: avoid_print
          print('[XChat][react_loop] blocked_layer_a (session=${s.id}, call=${call.id}): $e');
          return RunResult(RunKind.blockedLayerA, message: e.toString());
        } on BlockedExceptionYolo catch (e) {
          s.messages.add(Message(
            role: Role.tool,
            text: 'ERROR: $e',
            toolCallId: call.id,
            toolName: call.name,
          ));
          await SessionIo.write(s);
          BridgeEvents.emit('blocked_exception_yolo', {
            'sessionId': s.id,
            'callId': call.id,
            'cmd': args['cmd'] ?? '',
            'message': e.toString(),
          });
          // ignore: avoid_print
          print('[XChat][react_loop] blocked_exception_yolo (session=${s.id}, call=${call.id}): $e');
          return RunResult(RunKind.blockedExceptionYolo, message: e.toString());
        } catch (e) {
          // 其他异常:降级为 ERROR tool 消息,继续下一轮
          result = 'ERROR: $e';
          // ignore: avoid_print
          print('[XChat][react_loop] tool unexpected exception (session=${s.id}, call=${call.name}): $e');
          s.messages.add(Message(
            role: Role.tool,
            text: result,
            toolCallId: call.id,
            toolName: call.name,
          ));
          await SessionIo.write(s);
          BridgeEvents.emit('tool_done', {
            'sessionId': s.id,
            'callId': call.id,
            'name': call.name,
            'result': result,
          });
          continue;
        }

        s.messages.add(Message(
          role: Role.tool,
          text: result,
          toolCallId: call.id,
          toolName: call.name,
        ));
        await SessionIo.write(s);
        BridgeEvents.emit('tool_done', {
          'sessionId': s.id,
          'callId': call.id,
          'name': call.name,
          'result': result,
        });
        roundCount++;
      }

      if (roundCount >= s.maxRounds) {
        // 续会话
        final newId = uuidV4();
        final newS = s.clone(newId: newId);
        newS.title = '${s.title ?? "(续)"} (续)';
        await SessionIo.write(newS);
        BridgeEvents.emit('session_continued', {
          'oldId': s.id,
          'newId': newS.id,
          'reason': 'max_rounds',
        });
        s.id = newS.id;
        roundCount = 0;
        needsContinue = true;
      }
    }
  } catch (e, st) {
    // 修复:循环体内任何未捕获异常(典型如 Compressor.compress 写盘抛、TokenTracker.apply 抛)
    // 都会让 ReactLoop.run 异步失败,前端再也不会收到终止事件 → 输入框永久 disabled 表现为卡死。
    // 这里强制发 error 事件让前端 setRunning(false)。
    // ignore: avoid_print
    print('[XChat][react_loop] unhandled exception (session=${s.id}): $e\n$st');
    BridgeEvents.emit('error', {'sessionId': s.id, 'message': '$e'});
    return RunResult(RunKind.error, message: '$e');
  }
  }

  /// 修复: assistant 后必须紧跟对应 tool 结果元素(OpenAI 协议要求),
  /// 原实现丢掉了这一段。
  static List<Map<String, dynamic>> _buildMessages(ChatSession s) {
    final out = <Map<String, dynamic>>[];
    if (s.systemPrompt.trim().isNotEmpty) {
      out.add({'role': 'system', 'content': s.systemPrompt});
    }
    for (int i = 0; i < s.messages.length; i++) {
      final m = s.messages[i];
      if (m.role == Role.system) continue;
      switch (m.role) {
        case Role.user:
          out.add({'role': 'user', 'content': m.text});
          break;
        case Role.assistant:
          if (m.toolCalls.isEmpty) {
            out.add({'role': 'assistant', 'content': m.text});
          } else {
            final tcs = m.toolCalls.map((c) {
              return {
                'id': c.id,
                'type': 'function',
                'function': {'name': c.name, 'arguments': c.arguments},
              };
            }).toList();
            out.add({
              'role': 'assistant',
              'content': m.text.isEmpty ? null : m.text,
              'tool_calls': tcs,
            });
            // 紧跟 tool 结果:取该 assistant 之后连续的 tool 元素
            for (int j = i + 1; j < s.messages.length; j++) {
              final nxt = s.messages[j];
              if (nxt.role != Role.tool) break;
              out.add({
                'role': 'tool',
                'tool_call_id': nxt.toolCallId,
                'content': nxt.text,
              });
            }
          }
          break;
        case Role.tool:
          // 孤立的 tool 元素(没有前面的 assistant)跳过,避免协议错位
          break;
        case Role.system:
          break;
      }
    }
    return out;
  }
}
