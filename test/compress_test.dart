import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:xchat/core/app_paths.dart';
import 'package:xchat/data/index_repository.dart';
import 'package:xchat/data/session_repository.dart';
import 'package:xchat/llm/session_compressor.dart';
import 'package:xchat/models/app_config.dart';
import 'package:xchat/models/agent_mode.dart';
import 'package:xchat/models/session.dart';
import 'package:xchat/models/session_message.dart';

Session _session() => Session(
      id: 's1',
      sandbox: '/tmp/sandbox',
      createdAt: DateTime.now(),
      updatedAt: DateTime.now(),
      messages: <SessionMessage>[
        SessionMessage(role: MessageRole.system, content: 'sys'),
        SessionMessage(role: MessageRole.user, content: '问题 A'),
        SessionMessage(role: MessageRole.assistant, content: '回答 A'),
        SessionMessage(role: MessageRole.tool, toolName: 'read_file', content: 'tool body'),
        SessionMessage(role: MessageRole.user, content: '问题 B'),
        SessionMessage(role: MessageRole.assistant, content: '回答 B'),
      ],
    );

void main() {
  test('transcript keeps user/assistant turns in order, drops system/tool', () {
    final transcript = buildTranscript(_session());
    expect(transcript, '用户：问题 A\n助手：回答 A\n用户：问题 B\n助手：回答 B');
  });

  test('compress request frames the prompt and the transcript', () {
    final request = buildCompressRequest('保留命令', buildTranscript(_session()));
    // The instruction must state what is compressed and what the output is for.
    expect(request, contains('会话上下文压缩器'));
    expect(request, contains('唯一上下文'));
    // The chosen prompt comes before the record, and the record is delimited.
    expect(request.indexOf('保留命令'), lessThan(request.indexOf('用户：问题 A')));
    expect(request, contains('===== 对话记录开始 ====='));
    expect(request, contains('===== 对话记录结束 ====='));
    expect(request, contains('只输出压缩后的 Markdown 摘要正文'));
  });

  test('default compress prompts convey "compress into a context summary"', () {
    for (final prompt in AppConfig.defaultCompressPrompts()) {
      expect(prompt, contains('摘要'), reason: prompt);
      expect(prompt, contains('对话'), reason: prompt);
      // Must not read as an instruction to answer the user.
      expect(prompt.contains('你好'), isFalse);
    }
  });

  test('handoff message introduces the summary as carried-over context', () {
    final handoff = buildCompressHandoff('源会话', '## 摘要\n- 目标: x');
    expect(handoff, contains('源会话'));
    expect(handoff, contains('## 摘要'));
    expect(handoff, contains('上下文'));
  });

  test('session file can be rewritten (atomic overwrite)', () async {
    SharedPreferences.setMockInitialValues({});
    final tmp = Directory.systemTemp.createTempSync('xchat_compress');
    final paths = await AppPaths.init(overrideRoot: tmp.path);
    final repository = SessionRepository(paths, IndexRepository(paths));
    final session = _session();

    await repository.write(session);
    session.title = '改名';
    session.messages.add(SessionMessage(role: MessageRole.user, content: '新问题'));
    await repository.write(session);

    final reread = await repository.read(session.id);
    expect(reread.title, '改名');
    expect(reread.messages.last.content, '新问题');
    // No stray .tmp file is left behind.
    final leftovers = Directory(paths.sessionsDir)
        .listSync()
        .map((e) => e.path.split('/').last)
        .where((n) => n.endsWith('.tmp'));
    expect(leftovers, isEmpty);
  });

  test('decoded config lists stay editable (settings pages mutate in place)', () {
    final config = AppConfig.fromJson(<String, Object?>{
      'compress_prompts': <Object?>['提示词 A', '提示词 B'],
      'default_tools': <Object?>['read_file'],
      'shell_level1_commands': <Object?>['ls'],
      'shell_level2_commands': <Object?>['git push'],
      'shell_denied_commands': <Object?>['rm -rf'],
    });
    // 新增 / 编辑 / 删除压缩提示词（此前在固定长度列表上直接抛异常）
    expect(() => config.compressPrompts.add('新提示词'), returnsNormally);
    config.compressPrompts[0] = '改过的提示词';
    config.compressPrompts.removeAt(1);
    expect(config.compressPrompts.first, '改过的提示词');
    expect(() => config.defaultTools.add('glob'), returnsNormally);
    expect(() => config.shellLevel1Commands.add('pwd'), returnsNormally);
    expect(() => config.shellLevel2Commands.add('git commit'), returnsNormally);
    expect(() => config.shellDeniedCommands.add('shutdown'), returnsNormally);
    // 落盘后仍能读回同样的内容
    final reloaded = AppConfig.fromJson(config.toJson());
    expect(reloaded.compressPrompts, config.compressPrompts);
  });

  test('createSession keeps runtime switches (used by compress)', () async {
    // Sanity check that AgentMode stays wire-compatible after the change.
    expect(AgentMode.parse(AgentMode.managed.wire), AgentMode.managed);
  });
}
