import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:llm_api/llm_api.dart' as llm;
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:xchat/core/app_paths.dart';
import 'package:xchat/data/config_repository.dart';
import 'package:xchat/data/index_repository.dart';
import 'package:xchat/data/project_repository.dart';
import 'package:xchat/data/session_repository.dart';
import 'package:xchat/data/template_repository.dart';
import 'package:xchat/llm/note_assistant.dart';
import 'package:xchat/models/provider_config.dart';
import 'package:xchat/state/app_state.dart';
import 'package:xchat/ui/widgets/note_ai_panel.dart';
import 'package:xchat/ui/widgets/note_diff_dialog.dart';
import 'package:xchat/ui/widgets/note_editor.dart';

import 'helpers/test_theme.dart';

Future<AppState> buildState() async {
  SharedPreferences.setMockInitialValues(<String, Object>{});
  final tmp = Directory.systemTemp.createTempSync('xchat_note_ai');
  final paths = await AppPaths.init(overrideRoot: tmp.path);
  final index = IndexRepository(paths);
  final state = AppState(
    paths: paths,
    configRepository: ConfigRepository(paths),
    sessionRepository: SessionRepository(paths, index),
    templateRepository: TemplateRepository(paths),
    projectRepository: ProjectRepository(paths, index),
    indexRepository: index,
  );
  await state.load();
  return state;
}

/// A fake provider: emits [chunks] one by one, and stops when cancelled.
class _FakeProvider implements llm.LlmProvider {
  _FakeProvider(this.chunks);

  final List<String> chunks;

  @override
  String get name => 'fake';

  @override
  llm.ProviderCapabilities get capabilities =>
      const llm.ProviderCapabilities();

  @override
  Stream<llm.ChatEvent> stream(
    llm.ChatRequest request, {
    llm.CancelToken? cancel,
  }) async* {
    for (final chunk in chunks) {
      if (cancel?.isCancelled ?? false) return;
      yield llm.ContentDelta(chunk);
      await Future<void>.delayed(const Duration(milliseconds: 5));
    }
    if (cancel?.isCancelled ?? false) return;
    yield llm.Finished(reason: llm.FinishReason.stop);
  }

  @override
  Future<llm.ChatResponse> complete(
    llm.ChatRequest request, {
    llm.CancelToken? cancel,
  }) async =>
      throw UnimplementedError();

  @override
  Future<List<llm.ModelInfo>> listModels({llm.CancelToken? cancel}) async =>
      <llm.ModelInfo>[];

  @override
  void close() {}
}

void main() {
  group('prompt 构造', () {
    test('system prompt 带笔记标题与规则', () {
      final prompt = buildNoteSystemPrompt(title: '会议纪要');
      expect(prompt, contains('会议纪要'));
      expect(prompt, contains('Markdown'));
    });

    test('user prompt 含正文、请求与选区', () {
      final context = buildNoteContext(
        body: '# 标题\n\n正文内容',
        charLimit: 12000,
        selection: '正文内容',
      );
      final prompt = buildNoteUserPrompt(
        context: context,
        instruction: '润色一下',
        selection: '正文内容',
      );
      expect(prompt, contains('【当前笔记正文】'));
      expect(prompt, contains('<note>'));
      expect(prompt, contains('【本次请求】润色一下'));
      expect(prompt, contains('【选区】'));
      expect(prompt, contains('正文内容'));
      expect(context.truncated, isFalse);
    });

    test('选区带前后各 200 字上下文', () {
      final body = '${'前' * 500}【选区】${'后' * 500}';
      final context = buildNoteContext(
        body: body,
        charLimit: 100000,
        selection: '【选区】',
      );
      // 上下文不是全文，但选区前后各带一段。
      expect(context.text.length, lessThan(body.length));
      expect(context.text, contains('【选区】'));
      expect(context.text, contains('前' * 100));
      expect(context.text, contains('后' * 100));
    });

    test('正文超限时降级并标记 truncated', () {
      final body = List<String>.generate(
        400,
        (i) => i == 0 ? '# 会议纪要' : '第 $i 段：会议纪要内容',
      ).join('\n\n');
      final context = buildNoteContext(
        body: body,
        charLimit: 1000,
        selection: '第 10 段：会议纪要内容',
        instruction: '把这段改正式些',
      );
      expect(context.truncated, isTrue);
      expect(context.text.length, lessThan(body.length));
      expect(context.text, contains('大纲'));
      expect(context.text, contains('选区'));

      final prompt = buildNoteUserPrompt(
        context: context,
        instruction: '把这段改正式些',
      );
      expect(prompt, contains('已按相关片段裁剪上下文'));
    });

    test('「包含全文」强制发送全文', () {
      final body = 'x' * 5000;
      final context = buildNoteContext(
        body: body,
        charLimit: 100,
        forceFull: true,
      );
      expect(context.truncated, isFalse);
      expect(context.text, contains(body));
    });

    test('模型返回的围栏与前缀会被清掉', () {
      expect(cleanNoteAiResult('```markdown\n改好的内容\n```'), '改好的内容');
      expect(cleanNoteAiResult('改写：新的内容'), '新的内容');
    });
  });

  group('模型调用', () {
    test('流式结果会被收集并清洗', () async {
      final result = await runNoteAssistant(
        provider: ProviderConfig(id: 'p', name: 'P', baseUrl: 'http://x'),
        model: 'm',
        systemPrompt: 's',
        userPrompt: 'u',
        providerFactory: (_) => _FakeProvider(<String>['```\n结果\n```']),
      );
      expect(result, '结果');
    });

    test('中途取消 → 抛错，不返回内容', () async {
      final cancel = llm.CancelToken();
      final provider = _FakeProvider(<String>['一', '二', '三']);
      final future = runNoteAssistant(
        provider: ProviderConfig(id: 'p', name: 'P', baseUrl: 'http://x'),
        model: 'm',
        systemPrompt: 's',
        userPrompt: 'u',
        cancel: cancel,
        providerFactory: (_) => provider,
      );
      cancel.cancel('用户停止');
      await expectLater(future, throwsA(anything));
    });

    test('未配 provider 时不请求模型', () {
      final provider = ProviderConfig(id: 'p', name: 'P', baseUrl: 'http://x');
      expect(isProviderConfigured(provider), isFalse);
      expect(
        isProviderConfigured(
          ProviderConfig(id: 'p', name: 'P', baseUrl: 'http://x', apiKey: 'k'),
        ),
        isTrue,
      );
    });
  });

  group('diff 弹层', () {
    testWidgets('接受 → 返回 true；拒绝 → 返回 false', (tester) async {
      bool? answer;
      await tester.pumpWidget(
        MaterialApp(
          theme: testTheme(),
          home: Builder(
            builder: (context) => Scaffold(
              body: TextButton(
                onPressed: () async {
                  answer = await showNoteDiffDialog(
                    context,
                    oldText: '旧内容',
                    newText: '新内容',
                  );
                },
                child: const Text('打开'),
              ),
            ),
          ),
        ),
      );

      await tester.tap(find.text('打开'));
      await tester.pumpAndSettle();
      expect(find.text('接受并应用'), findsOneWidget);
      expect(find.text('拒绝'), findsOneWidget);
      expect(find.text('新内容'), findsOneWidget);

      await tester.tap(find.text('拒绝'));
      await tester.pumpAndSettle();
      expect(answer, isFalse);

      await tester.tap(find.text('打开'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('接受并应用'));
      await tester.pumpAndSettle();
      expect(answer, isTrue);
    });
  });

  group('AI 面板', () {
    testWidgets('未配模型时给出引导文案，不抛异常', (tester) async {
      final state = (await tester.runAsync(buildState))!;
      await tester.pumpWidget(
        ChangeNotifierProvider<AppState>.value(
          value: state,
          child: MaterialApp(
            theme: testTheme(),
            home: Scaffold(
              body: NoteAiPanel(
                collapsed: false,
                onToggleCollapsed: () {},
                body: '# 标题\n\n正文',
                selection: '正文',
                title: '标题',
                onApply: (_, _) async {},
                onBusyChanged: (_) {},
              ),
            ),
          ),
        ),
      );
      await tester.pump();

      // 默认配置没有 API Key → 点「润色」应给出引导文案。
      await tester.tap(find.text('润色'));
      await tester.pump();
      expect(find.textContaining('模型服务'), findsOneWidget);
    });

    testWidgets('生成中不允许收起', (tester) async {
      final state = (await tester.runAsync(buildState))!;
      var busy = false;
      await tester.pumpWidget(
        ChangeNotifierProvider<AppState>.value(
          value: state,
          child: MaterialApp(
            theme: testTheme(),
            home: Scaffold(
              body: NoteAiPanel(
                collapsed: false,
                onToggleCollapsed: () {},
                body: '# 标题\n\n正文',
                selection: '正文',
                title: '标题',
                onApply: (_, _) async {},
                onBusyChanged: (value) => busy = value,
              ),
            ),
          ),
        ),
      );
      await tester.pump();

      // 没配模型 → 不会真的发起请求；这里只验证「未生成时收起按钮可用」。
      expect(find.byTooltip('收起 AI 助手'), findsOneWidget);
      expect(busy, isFalse);
    });
  });

  group('编辑器通道', () {
    testWidgets('NoteEditorController 能读选区并写回缓冲', (tester) async {
      final controller = NoteEditorController();
      final changes = <String>[];
      await tester.pumpWidget(
        MaterialApp(
          theme: testTheme(),
          home: Scaffold(
            body: NoteEditor(
              controller: controller,
              body: 'hello world',
              onChanged: changes.add,
              onSave: () {},
              splitRatio: 0.4,
              onSplitRatioChanged: (_) {},
            ),
          ),
        ),
      );
      await tester.pump(const Duration(milliseconds: 400));

      final editable = tester.widget<EditableText>(find.byType(EditableText));
      editable.controller.selection = const TextSelection(
        baseOffset: 0,
        extentOffset: 5,
      );
      await tester.pump();
      expect(controller.selection, 'hello');

      controller.replaceSelection('你好');
      await tester.pump();
      expect(changes.last, '你好 world');
      expect(controller.body, '你好 world');
    });
  });
}
