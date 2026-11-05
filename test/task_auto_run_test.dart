import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:xchat/core/app_paths.dart';
import 'package:xchat/data/index_repository.dart';
import 'package:xchat/data/session_repository.dart';
import 'package:xchat/models/app_config.dart';
import 'package:xchat/models/provider_config.dart';
import 'package:xchat/models/session.dart';
import 'package:xchat/models/session_message.dart';
import 'package:xchat/models/task_item.dart';
import 'package:xchat/models/token_usage.dart';
import 'package:xchat/session/session_controller.dart';

/// 自动执行的编排验证：不联网，用 [SessionController.debugTaskTurn] 顶替
/// 真正的一轮。（编排逻辑在 controller 里，这是唯一需要被替换的那一步。）
Future<SessionController> _controller(Session session) async {
  final tmp = Directory.systemTemp.createTempSync('xchat_autorun');
  final paths = await AppPaths.init(overrideRoot: tmp.path);
  final repository = SessionRepository(paths, IndexRepository(paths));
  final controller = SessionController(
    repository: repository,
    config: AppConfig(),
    providerResolver: (id) =>
        ProviderConfig(id: 'p', baseUrl: 'https://example.com/v1'),
  );
  controller.open(session);
  return controller;
}

Session _session({List<TaskItem>? tasks, List<SessionMessage>? messages}) =>
    Session(
      id: 'ts1',
      sandbox: '/tmp/xchat_autorun_sandbox',
      createdAt: DateTime.utc(2025),
      updatedAt: DateTime.utc(2025),
      kind: SessionKind.task,
      tasks: tasks ??
          [
            TaskItem(id: 't1', title: '任务一', content: '做第一件事'),
            TaskItem(id: 't2', title: '任务二', content: '做第二件事'),
          ],
      messages: messages ?? [SessionMessage(role: MessageRole.system, content: 'sys')],
    );

/// 假的一轮：往会话里追加一条 assistant 回复并记账用量。
void _fakeTurn(Session session, String taskId, {TokenUsage? usage}) {
  session.messages.add(SessionMessage(
    role: MessageRole.assistant,
    id: 'a-$taskId',
    content: '完成了 $taskId',
    taskId: taskId,
    usage: usage ?? const TokenUsage(input: 100, output: 20),
  ));
  if (usage == null) {
    session.cumulativeUsage =
        session.cumulativeUsage.merge(const TokenUsage(input: 100, output: 20));
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() => SharedPreferences.setMockInitialValues(<String, Object>{}));

  group('自动执行候选', () {
    test('排除已完成，默认也排除已有回复的', () {
      final session = _session(
        tasks: [
          TaskItem(id: 't1', title: '一'),
          TaskItem(id: 't2', title: '二', done: true),
          TaskItem(id: 't3', title: '三'),
        ],
        messages: [
          SessionMessage(role: MessageRole.system, content: 'sys'),
          SessionMessage(role: MessageRole.user, id: 'u3', taskId: 't3', content: 'x'),
          SessionMessage(role: MessageRole.assistant, id: 'a3', taskId: 't3', content: 'y'),
        ],
      );
      expect(session.autoRunCandidates().map((t) => t.id), ['t1']);
      expect(
        session.autoRunCandidates(includeReplied: true).map((t) => t.id),
        ['t1', 't3'],
      );
    });
  });

  group('seedTaskMessage', () {
    test('把任务内容写成第一条 user 消息，重复调用不重复插入', () async {
      final session = _session();
      final controller = await _controller(session);
      final task = session.tasks.first;
      expect(await controller.seedTaskMessage(task), isTrue);
      expect(session.taskMessages('t1').single.role, MessageRole.user);
      expect(session.taskMessages('t1').single.content, '做第一件事');

      expect(await controller.seedTaskMessage(task), isTrue);
      expect(session.taskMessages('t1').length, 1);
    });

    test('没有内容的任务返回 false，不插消息', () async {
      final session = _session(tasks: [TaskItem(id: 't1')]);
      final controller = await _controller(session);
      expect(await controller.seedTaskMessage(session.tasks.first), isFalse);
      expect(session.messages.length, 1);
    });
  });

  group('runTasksAuto', () {
    test('逐项执行，跑完自动勾选完成', () async {
      final session = _session();
      final controller = await _controller(session);
      final order = <String>[];
      controller.debugTaskTurn = (taskId) async {
        order.add(taskId);
        _fakeTurn(session, taskId);
      };

      await controller.runTasksAuto(taskIds: ['t1', 't2']);

      expect(order, ['t1', 't2']);
      expect(session.tasks.every((t) => t.done), isTrue);
      expect(controller.autoRunning, isFalse);
      expect(controller.autoDoneCount, 2);
      expect(controller.autoTotal, 2);
      expect(controller.autoFailure, isNull);
      expect(controller.autoResumeTaskId, isNull);
      // 本次用量 = 会话累计的增量。
      expect(controller.autoUsage.input, 200);
      expect(controller.autoUsage.output, 40);
    });

    test('关掉「自动勾选完成」时只跑不标记', () async {
      final session = _session();
      final controller = await _controller(session);
      controller.debugTaskTurn = (taskId) async {
        _fakeTurn(session, taskId);
      };

      await controller.runTasksAuto(
        taskIds: ['t1', 't2'],
        markDoneWhenFinished: false,
      );
      expect(session.tasks.any((t) => t.done), isFalse);
      expect(controller.autoDoneCount, 2);
    });

    test('已完成的任务不发（锁定语义）', () async {
      final session = _session(
        tasks: [
          TaskItem(id: 't1', title: '一', done: true),
          TaskItem(id: 't2', title: '二'),
        ],
      );
      final controller = await _controller(session);
      final order = <String>[];
      controller.debugTaskTurn = (taskId) async {
        order.add(taskId);
        _fakeTurn(session, taskId);
      };

      await controller.runTasksAuto(taskIds: ['t1', 't2']);
      expect(order, ['t2']);
    });

    test('某项报错即停下，并记住该项供下次重跑', () async {
      final session = _session();
      final controller = await _controller(session);
      controller.debugTaskTurn = (taskId) async {
        if (taskId == 't2') throw StateError('boom');
        _fakeTurn(session, taskId);
      };

      await controller.runTasksAuto(taskIds: ['t1', 't2']);

      expect(controller.autoDoneCount, 1);
      expect(controller.autoFailure, contains('任务二'));
      expect(controller.autoResumeTaskId, 't2');
      expect(session.tasks.first.done, isTrue);
      expect(session.tasks.last.done, isFalse);
      // 出错那一项没有 assistant 回复 → 下次仍在「未开始」候选里。
      expect(session.autoRunCandidates().map((t) => t.id), ['t2']);
    });

    test('停止自动执行：不再开始下一项，记住中断项', () async {
      final session = _session();
      final controller = await _controller(session);
      final order = <String>[];
      controller.debugTaskTurn = (taskId) async {
        order.add(taskId);
        _fakeTurn(session, taskId);
        // 第一项跑完时用户点了「停止自动执行」。
        if (taskId == 't1') controller.cancelAutoRun();
      };

      await controller.runTasksAuto(taskIds: ['t1', 't2']);

      expect(order, ['t1']);
      expect(controller.autoRunning, isFalse);
      expect(controller.autoResumeTaskId, 't1');
      expect(session.tasks.last.done, isFalse);
    });

    test('无内容任务跳过但不打断整条链', () async {
      final session = _session(
        tasks: [
          TaskItem(id: 't0'),
          TaskItem(id: 't1', title: '一', content: '做第一件事'),
        ],
      );
      final controller = await _controller(session);
      controller.debugTaskTurn = (taskId) async {
        _fakeTurn(session, taskId);
      };

      await controller.runTasksAuto(taskIds: ['t0', 't1']);
      expect(controller.autoSkipped, 1);
      expect(controller.autoDoneCount, 1);
      expect(controller.autoFailure, isNull);
    });
  });
}
