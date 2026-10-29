import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:xchat/core/app_paths.dart';
import 'package:xchat/data/config_repository.dart';
import 'package:xchat/data/index_repository.dart';
import 'package:xchat/data/project_repository.dart';
import 'package:xchat/data/session_repository.dart';
import 'package:xchat/data/template_repository.dart';
import 'package:xchat/models/session.dart';
import 'package:xchat/models/session_message.dart';
import 'package:xchat/models/task_item.dart';
import 'package:xchat/state/app_state.dart';
import 'package:xchat/ui/pages/home_page.dart';
import 'package:xchat/ui/widgets/task_session_view.dart';

Future<AppState> buildState() async {
  SharedPreferences.setMockInitialValues({});
  final tmp = Directory.systemTemp.createTempSync('xchat_task');
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
  final session = await state.createSession(
    title: '任务会话',
    kind: SessionKind.task,
    tasks: [
      TaskItem(id: 't1', title: '任务一', content: '做第一件事'),
      TaskItem(id: 't2', title: '任务二', content: '做第二件事'),
    ],
  );
  session.messages.addAll([
    SessionMessage(
        role: MessageRole.user, id: 'u1', content: '做第一件事', taskId: 't1'),
    SessionMessage(
        role: MessageRole.assistant, id: 'a1', content: '第一件已完成', taskId: 't1'),
  ]);
  await state.sessionRepository.write(session);
  await state.refreshSessions();
  return state;
}

Future<void> pumpHome(WidgetTester tester, AppState state) async {
  await tester.pumpWidget(
    ChangeNotifierProvider<AppState>.value(
      value: state,
      child: const MaterialApp(home: HomePage()),
    ),
  );
  await tester.pump(const Duration(milliseconds: 50));
}

/// Pumps until [finder] matches, letting real async I/O progress in between
/// (opening a session reloads it from disk).
Future<void> pumpUntilFound(
  WidgetTester tester,
  Finder finder, {
  Duration timeout = const Duration(seconds: 10),
}) async {
  final deadline = DateTime.now().add(timeout);
  while (DateTime.now().isBefore(deadline)) {
    await tester.pump(const Duration(milliseconds: 20));
    if (finder.evaluate().isNotEmpty) return;
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 20)),
    );
  }
  fail('等待超时：$finder');
}

void main() {
  testWidgets('任务式会话：先任务列表，再点进单个任务的对话', (tester) async {
    tester.view.physicalSize = const Size(1400, 900);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    late AppState state;
    await tester.runAsync(() async => state = await buildState());
    await pumpHome(tester, state);

    // 打开任务式会话 → 任务列表（而不是对话）。
    await tester.tap(find.text('任务会话').first);
    await pumpUntilFound(tester, find.byType(TaskListView));
    expect(find.text('任务一'), findsOneWidget);
    expect(find.text('任务二'), findsOneWidget);
    expect(find.textContaining('共 2 项'), findsOneWidget);

    // 点进「任务二」（尚无回复）→ 弹窗询问是否发送。
    await tester.tap(find.text('任务二'));
    await pumpUntilFound(tester, find.text('开始这个任务？'));
    await tester.tap(find.text('稍后（先看任务）'));
    await tester.pumpAndSettle();

    // 只显示该任务的消息：任务一的内容不该出现在这里。
    expect(find.byType(SessionChatPanel), findsOneWidget);
    expect(find.text('做第一件事'), findsNothing);
    expect(find.text('第一件已完成'), findsNothing);

    // 返回任务列表。
    await tester.tap(find.byTooltip('返回任务列表'));
    await pumpUntilFound(tester, find.byType(TaskListView));
    expect(find.text('任务一'), findsOneWidget);
  });

  testWidgets('任务列表：勾选完成会落盘', (tester) async {
    tester.view.physicalSize = const Size(1400, 900);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    late AppState state;
    await tester.runAsync(() async => state = await buildState());
    await pumpHome(tester, state);
    await tester.tap(find.text('任务会话').first);
    await pumpUntilFound(tester, find.byType(TaskListView));

    // 第一行的复选框 = 任务一。
    await tester.tap(find.byType(Checkbox).first);
    await tester.pump(const Duration(milliseconds: 20));

    // 落盘是异步的：真实事件循环 + 假时钟交替推进，直到磁盘上出现 done。
    final id = state.sessions.first.id;
    var done = false;
    final deadline = DateTime.now().add(const Duration(seconds: 10));
    while (!done && DateTime.now().isBefore(deadline)) {
      await tester.pump(const Duration(milliseconds: 20));
      final onDisk = await tester.runAsync(
        () => state.sessionRepository.read(id),
      );
      done = onDisk!.tasks.first.done;
    }
    expect(done, isTrue);
  });
}
