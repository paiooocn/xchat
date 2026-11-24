import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:xchat/core/app_paths.dart';
import 'package:xchat/data/config_repository.dart';
import 'package:xchat/data/index_repository.dart';
import 'package:xchat/data/project_repository.dart';
import 'package:xchat/data/session_repository.dart';
import 'package:xchat/data/template_repository.dart';
import 'package:xchat/models/expertise.dart';
import 'package:xchat/state/app_state.dart';
import 'package:xchat/ui/pages/expertise_page.dart';
import 'helpers/test_theme.dart';

Future<AppState> _buildState() async {
  SharedPreferences.setMockInitialValues({});
  final tmp = Directory.systemTemp.createTempSync('xchat_expertise_ui');
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

Future<void> _pumpPage(WidgetTester tester, AppState state) async {
  await tester.pumpWidget(
    ChangeNotifierProvider<AppState>.value(
      value: state,
      child: MaterialApp(theme: testTheme(), home: const ExpertisePage()),
    ),
  );
  await tester.pumpAndSettle();
}

/// 真实文件 I/O：让假时钟与真实事件循环交替，直到 [done] 成立。
Future<void> _flush(WidgetTester tester, bool Function() done) async {
  for (var i = 0; i < 100 && !done(); i++) {
    await tester.pump();
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 20)),
    );
  }
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('列出内置专长并支持添加、编辑、停用、删除', (tester) async {
    tester.view.physicalSize = const Size(900, 2200);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    late AppState state;
    await tester.runAsync(() async {
      state = await _buildState();
    });
    await _pumpPage(tester, state);

    expect(find.text('编程开发'), findsOneWidget);
    expect(find.text('内置'), findsWidgets);

    // ---- 添加 ----
    await tester.tap(find.text('添加专长'));
    await tester.pumpAndSettle();

    await tester.enterText(find.widgetWithText(TextField, '名称'), '我的专长');
    await tester.pump();
    await tester.enterText(
      find.widgetWithText(TextField, '提示词内容（多个专长时按排序拼接，段间用 --- 分隔）'),
      '自定义提示词',
    );
    await tester.pump();
    await tester.enterText(find.widgetWithText(TextField, '排序序号（越小越靠前；多个专长按此顺序组合）'), '3');
    await tester.pump();
    await tester.tap(find.text('保存'));
    await _flush(tester, () => state.expertises.any((e) => e.name == '我的专长'));

    expect(state.expertises.any((e) => e.name == '我的专长'), isTrue);
    final added = state.expertises.firstWhere((e) => e.name == '我的专长');
    expect(added.sort, 3);
    expect(File(state.paths.expertiseFile).existsSync(), isTrue);

    // ---- 编辑 ----
    await tester.tap(
      find.descendant(
        of: find.widgetWithText(ListTile, '我的专长'),
        matching: find.byTooltip('编辑'),
      ),
    );
    await tester.pumpAndSettle();
    await tester.enterText(find.widgetWithText(TextField, '名称'), '我的专长（改）');
    await tester.pump();
    await tester.tap(find.text('保存'));
    await _flush(
      tester,
      () => state.expertises.any((e) => e.name == '我的专长（改）'),
    );
    expect(state.expertises.any((e) => e.name == '我的专长（改）'), isTrue);

    // ---- 停用 ----
    final before = state.expertises.firstWhere((e) => e.name == '编程开发');
    await tester.tap(
      find.descendant(
        of: find.widgetWithText(ListTile, '编程开发'),
        matching: find.byType(Switch),
      ),
    );
    await _flush(
      tester,
      () =>
          state.expertises.firstWhere((e) => e.id == before.id).enabled == false,
    );
    expect(
      state.expertises.firstWhere((e) => e.id == before.id).enabled,
      isFalse,
    );

    // ---- 删除 ----
    await tester.tap(
      find.descendant(
        of: find.widgetWithText(ListTile, '编程开发'),
        matching: find.byTooltip('删除'),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(FilledButton, '删除'));
    await _flush(
      tester,
      () => !state.expertises.any((e) => e.id == before.id),
    );
    expect(state.expertises.any((e) => e.id == before.id), isFalse);

    // 重新读盘：删除的内置项不复活（墓碑生效），新增/改名仍在。
    await tester.runAsync(() => state.refreshExpertises());
    await tester.pumpAndSettle();
    expect(state.expertises.any((e) => e.id == before.id), isFalse);
    expect(state.expertises.any((e) => e.name == '我的专长（改）'), isTrue);
  });

  testWidgets('空库显示空状态', (tester) async {
    tester.view.physicalSize = const Size(900, 1200);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    late AppState state;
    await tester.runAsync(() async {
      state = await _buildState();
      state.expertises = <Expertise>[];
    });
    await _pumpPage(tester, state);
    expect(find.text('暂无可用的 AI 专长。'), findsOneWidget);
  });

  testWidgets('查看专长详情并复制提示词', (tester) async {
    tester.view.physicalSize = const Size(900, 2200);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    String? copied;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(SystemChannels.platform, (call) async {
      if (call.method == 'Clipboard.setData') {
        copied = (call.arguments as Map)['text'] as String?;
      }
      return null;
    });
    addTearDown(() {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(SystemChannels.platform, null);
    });

    late AppState state;
    await tester.runAsync(() async {
      state = await _buildState();
    });
    await _pumpPage(tester, state);

    // 点击行查看详情：完整说明 + 提示词。
    await tester.tap(find.widgetWithText(ListTile, '编程开发'));
    await tester.pumpAndSettle();
    expect(find.text('提示词（可直接提供给 Agent）'), findsOneWidget);
    expect(find.byType(SelectableText), findsOneWidget);
    await tester.tap(find.text('复制提示词'));
    await tester.pumpAndSettle();
    expect(copied, contains('你擅长编程开发'));

    // 行内「复制提示词」图标。
    await tester.tap(
      find.descendant(
        of: find.widgetWithText(ListTile, '数据与数据库'),
        matching: find.byTooltip('复制提示词'),
      ),
    );
    await tester.pumpAndSettle();
    expect(copied, contains('你擅长数据与数据库'));
  });
}
