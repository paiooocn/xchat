# XChat 雷区清单（GOTCHAS）

> 只写**容易踩、且踩了不容易立刻发现**的坑。每条都给出源码位置或设计文档章节。
> 通用说明在 `DESIGN.md`，这里只做提醒。

## 1. 会话 XML：格式化会毁掉存档

- **不能用通用 pretty printer / XML formatter**。会话正文一律 CDATA，
  通用 formatter 会往 CDATA 里注入缩进空白，导致「读出来多出换行」的往返破坏。
  → `lib/data/xml/xml_writer.dart` 的 `XmlOut` 是手写的，原因就在这。
- **CDATA 里出现 `]]>` 必须拆开**：写成 `]]]]><![CDATA[>`，否则提前闭合。
  → `XmlOut._cdata`。
- **新增字段必须同步读写两侧，且必须能读旧文件**。会话 XML 是用户长期存档，不能改语义。
  → `lib/data/xml/session_xml.dart`。

## 2. 数据目录解析：不能抛异常

`AppPaths.init()` 拿不到可写目录时**必须降级**（私有目录 / 用户自选目录），
一旦抛出就会在 `runApp` 之前崩掉，用户连设置页都进不去。
→ `lib/core/app_paths.dart`、`lib/main.dart` 的 `try/catch`。

## 3. 沙箱：两道防线缺一不可

- `PathGuard.resolve` 只拦 `..` 越界；
- `PathGuard.resolveReal` 还会跟随符号链接，防「软链逃逸」。
  真正读写文件时应走后者。
→ `lib/agent/tools/path_guard.dart`。
- `agent.tools` 里的工具调用**不要绕过 PathGuard 直接用 `File(path)`**。

## 4. 思考内容：两种形态都要回发

`reasoning_content`（deepseek/kimi/glm/mimo）与 `<think>`（minimax）是两套通道，
**两种都要显示、也都要回发**给模型，否则模型下一轮看不到自己的推理。
回发策略优先级：会话显式模式 > provider 默认 > 由预设推导。
→ `lib/llm/outbound_adapter.dart` 的 `resolveEchoMode`；`DESIGN.md §7.2`。

## 5. tool 协议：出站前必须修复

OpenAI 兼容端点要求 `assistant` 的 `tool_calls` 后**恰好**跟一条对应 `tool` 消息。
缺回复（turn 中途停了、工具消息被删）→ 补错误占位；
孤儿 `tool` 消息 → 丢弃。否则整个请求被拒
（`insufficient tool messages following tool calls message`）。
→ `lib/llm/outbound_adapter.dart` 的出站修复函数。

## 6. shell：分级与启动器是两件事

- 命令分级（哪些命令要审批）由 `shell_policy` 的正则名单决定，与启动器无关。
- 启动器（可执行文件 + `{command}` 模板）由 `shell_exec` 决定，Windows/POSIX 语法不同。
- 输出解码要考虑编码与截断（曾因截断导致结果不可用）。
→ `lib/models/shell_policy.dart`、`lib/models/shell_exec.dart`。

## 7. index.json 是缓存，不是事实

- 加载时必须拿目录列表校验磁盘，不一致就重建 —— 别的实例可能已增删会话。
- **写路径不能每次全量重建**：保存一次会话就重建整个目录会随会话数线性变慢
  （曾经几十毫秒起步）。写路径只做增量合并。
→ `lib/data/index_repository.dart`（`load` 与 `_loadForWrite` 两条路径不同）。

## 8. 渲染层：三个已修过的坑

- **选中复制后粘贴必须保留换行**（v0.5.6 修过一次）。
- **v0.5.6 的换行补丁有一个副作用：代码围栏之后的内容选不中**（2026-10-29 已修）。
  机制见下面 §8.1。
- 公式用 KaTeX 兼容的 TeX 布局，`$…$` / `$$…$$` 两种都要处理，归一化在 `math_support.dart`。
→ `lib/ui/widgets/markdown_view.dart`、`lib/ui/widgets/math_support.dart`。

### 8.1 SelectionArea 与 WidgetSpan：隐藏的零尺寸段落会截断选区

`SelectionArea` 的选区靠 `Selectable` 列表的**屏幕顺序**串联（Flutter
`MultiSelectableSelectionContainerDelegate`）。两处会踩雷：

1. **`WidgetSpan` 边界不可跨越**：`RenderParagraph` 在 `PlaceholderSpan` 处把
   段落切成多个 `_SelectableFragment`，选区**不能**跨过 `WidgetSpan`。
   → 代码围栏 / 表格 / 列表都是 `WidgetSpan`。
2. **零尺寸的 `Text` 会毁掉顺序比较**：`_compareScreenOrder` 用包围盒排序，
   高度 0、宽度也为 0 的段落（`Text('\n')` 的换行符没有前进宽度 → 宽 0）
   包围盒退化，导致它与后一段的先后关系判错，选区扩展到那里就停住。

v0.5.6 为修「粘贴丢换行」，给每个文本块后面加了一个隐藏的
`SizedBox(height: 0, child: Text('\n'))`。这个隐藏段落被
`_SafeCodeBlockNode` 里的 `ProxyRichText` **注入了代码围栏的 `WidgetSpan`
子树内部**，于是代码围栏后面所有段落都选不中（实测：列表 / 引用 / 标题 /
表格 / 公式都不触发，**只有代码围栏触发**）。

复现（widget test）：拖选整段 → 剪贴板里围栏之后的内容消失。

**修法（已实施）**：围栏内部不走 `richTextBuilder`（自己拼 `Text.rich`）。
围栏与后续段落之间的换行由该块在顶层拿到的 break 提供，不用围栏内部补。
→ `lib/ui/widgets/markdown_view.dart` 的 `_SafeCodeBlockNode.build()`。
回归测试：`test/markdown_copy_test.dart`
（"text after a code fence stays selectable"）。

**推论**：以后再加「隐藏文本」类的小组件，**不要放进 `WidgetSpan` 子树**，
否则同样会截断选区。

## 9. 会话并行：controller 不能随手 dispose

切换会话只换面板，**不销毁** `SessionController` —— 否则正在跑的 turn 被打断，
多会话并行就废了。审批队列是全局的，turn 被停止时要主动摘掉本会话的待审批项，
否则会钉住 agent。
→ `lib/session/session_controller.dart`、`lib/state/approval_center.dart`。

## 10. 平台差异

- **Android 15+ 边到边**：底部安全区用 `MediaQuery.paddingOf(context).bottom`，
  **不要用 `viewPadding.bottom`**（键盘弹出时会留空隙）。见 `lib/app.dart` 的注释。
- **WebView 搜索**：Linux 构建需要 `libwebkit2gtk-4.1-dev`。
- **桌面窗口尺寸**：先 best-effort 设置，首帧后再幂等重放一次 resize，
  否则会被 GTK/WM 丢掉（v0.3.4 修过）。
- **移动端没有外部编辑器**能力，`lib/util/editor_launcher.dart` 的调用要判平台。

## 11. Python 运行时注入

- `PATH` **只前置不覆盖**（v0.4.1 修过：Windows 大小写、PYTHONPATH 透传、输出截断）。
- Windows 侧要补 `python3.exe` 别名，否则 `python3` 命令不存在。
- `PIP_INDEX_URL` 走镜像链（清华→阿里→官方），改这里要同步 `pip_indexes`。
→ `lib/core/python_runtime.dart`。

## 12. 代码风格约定

- **包内互相引用用相对路径**（`import '../core/app_paths.dart';`），
  不是 `package:xchat/...`；外部包才用 `package:` 前缀。
  新增文件请跟随这个约定 —— 生成器 `tool/gen_memory_index.dart` 依赖它来还原依赖图。

## 13. 隐性契约清单（改之前扫一眼）

- token 用量口径：单次写 assistant，累计写 system（`DESIGN.md §8`）。
- 克隆会话只复制到**第一个 user 元素**为止（`DESIGN.md §11.5`）。
- 「编辑最近一条 user 消息」= 重发，不是新增一轮（`DESIGN.md §11.4`）。
- 工具次数上限用尽后追加的是 **user 消息**，由模型自判是否继续（`DESIGN.md §9.2`）。
- 新建会话的系统提示词首行自动写入工作空间根目录（v0.3.1）。
- 图片附件是 **base64 内联**传输，有大小上限，超限直接丢弃而不是截断（`DESIGN.md §10.1.1`）。

## 14. widget test 里保存类操作要走真实 I/O

`testWidgets` 跑在**假时钟**里：`pumpAndSettle()` 只等「有没有待绘制的帧」，
**不等挂起的真实 I/O**（写盘 / 读盘）。所以「点保存 → 断言数据已落盘」这类用例
会**假失败**：断言跑在保存完成之前，`state.xxx` 还是旧的。

两个都要用，且必须**交替**：

- `tester.pump()` —— 让假时钟里的微任务继续（await 的续体在这里跑）；
- `tester.runAsync(() => Future.delayed(...))` —— 让真实事件循环转起来，
  真实 I/O 才能完成。

只写 `runAsync` 不够：它跑的时候假时钟是暂停的，I/O 完成后回调排在假时钟的
微任务队列里，没人 drain；反过来只 `pump` 也不行，真实 I/O 根本没机会完成。

正确写法（保存 → 重新读盘这种两段式异步最容易踩）：

```dart
await tester.tap(find.text('保存'));
for (var i = 0; i < 30; i++) {
  await tester.pump();
  await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 10)));
  if (state.templates.any((t) => t.params.maxTokens == 4096)) break;
}
```

顺带：断言**内存态**（如 `state.config.providers`，`upsertProvider` 在内存里改）
不受影响，所以不是所有保存类用例都会踩。
→ 参考用例 `test/template_max_tokens_test.dart`。

## 15. 归档页：项目 = 父项，会话 = 子项

- 归档页两个 Tab：**归档·全局**（`projectId` 为空的归档会话）与
  **归档·项目**（父项=项目，子项=该项目的归档会话，父项默认折叠）。
- 父项出现的条件：**项目已归档** 或 **其下有归档会话**；徽标规则见
  `models/archive_group.dart` 的 `ArchiveBadge`（「全部」= 项目已归档且会话全归档；
  「部分」= 有归档会话但不满足「全部」；项目无会话 → 无徽标）。
- 分组/计数是**纯函数**（`buildArchiveProjectGroups`），别在 widget 里现算，
  否则徽标规则会散落到 UI 层、测试不到。
- 排序用 `project.name`（空名排末尾）；中文名按码位比较，`已` < `有`，
  写测试断言时别想当然地按插入顺序。

## 16. 写会话后要同时刷新「活动」与「归档」两个列表

`AppState` 有两套列表：`sessions`（活动）与 `archivedSessions`（归档）。
**任何可能作用在归档会话上的写操作**（删除 / 重命名 / 改标签）都只重建了活动列表，
归档页就会显示陈旧数据，直到重启应用自愈（磁盘 index.json 其实是对的）。

- 症状对照：删了归档会话但行还在；重命名归档会话但标题是旧的。
- 修法：先 `await refreshArchived();` 再 `await refreshSessions();`
  （顺序不能反：`_pruneCache` 依赖最新的归档集合）。
- 参考：`AppState.deleteSession` / `renameSession` / `setSessionTags`，
  回归用例在 `test/archive_page_test.dart`。

## 17. 改名版（SixChat）：显示名只有一个来源，但原生侧要各自注入

需求：每次 build 多打一个只改应用名的版本（XChat → SixChat）。做法是**构建期注入**，
源码零分支。三个坑：

- **Gradle 拿到的 `dart-defines` 是 base64 过的**：flutter 把**每个** `--dart-define`
  单独 base64 编码，再用 "," 连接（`build_info.dart` 的 `encodeDartDefines`）。
  Gradle 侧要先 split(",") 再逐条 base64 解码，解出来才是 `KEY=VALUE`。
  见 `android/app/build.gradle.kts` 的 `appName`。
- **CMake 不会因为环境变量变了就重新 configure**：`APP_BRAND_NAME` 走环境变量，
  但 CMake 缓存不失效 → 改名版会拿到上一次的显示名（窗口标题不变）。
  打包脚本里必须在改名版构建前删掉 `build/linux`（Windows 是 `build\windows`），
  强制重新 configure。见 `dist/build_deb.sh` / `dist/build_windows.ps1`。
- **原生窗口标题不读 Dart 常量**：Linux/Windows 的标题在 C++ 里写死，
  靠 CMake 注入编译宏 `APP_BRAND_NAME`；Android 启动器名字靠
  `resValue("string", "app_name")` + manifest 的 `@string/app_name`。
  三处（Dart / Gradle / CMake）必须给**同一个**名字。
- **AGP 9 要显式开 `resValues`**：`defaultConfig { resValue("string","app_name",…) }`
  会报「defaultConfig contains custom resource values, but the feature is disabled」，
  必须在 `android { buildFeatures { resValues = true } }` 里打开。
- **只改显示名**：applicationId（`com.yimo.xchat`）、deb 包名、数据目录都不变，
  所以改名版与正式版**不能共存**（装谁覆盖谁，数据共用）。要共存得另开
  applicationId / 包名 / 数据目录，那是另一件事。

## 18. 笔记文件（Markdown + front-matter）

笔记是**给人读的纯文本**，往返规则比会话 XML 更严格：

- **正文逐字保留**：写回时只重写 front-matter 块，正文原样落盘（禁止格式化、
  禁止补/删尾部换行）。解析时只吃掉 front-matter 与正文之间的**一个**空行 ——
  多吃一个就会吞掉用户正文开头的空行。
- **未知 front-matter key 必须原样保留**（存在 `Note.extra` 里），否则外部工具
  （Obsidian 等）写的字段会被清掉。已知 key 是白名单：`id/title/tags/created_at/
  updated_at/pinned/archived_at`。
- **列表扫描只读文件头 4KB**（`noteHeadBytes`）：front-matter 装不下时才回退读全文；
  头部里 `---` 没闭合会被当成「裸 Markdown」（标题取正文首个 `# ` 标题）。
  → `lib/data/xml/note_md.dart`、`lib/data/index_repository.dart` 的 `_readNoteHead`。
- **裸 Markdown 不是错误**：没有 front-matter 的 `.md` 会被导入为笔记（补齐头部）。
- **改 `CatalogIndex.version` 会作废旧索引**（既定机制）—— 同时要改断言版本号的
  测试（`test/task_session_test.dart` 里 `expect(CatalogIndex.version, 4)`）。
- **`IndexRepository.load()` 先校验磁盘**：想测「旧索引被丢弃重建」必须用**新的
  `IndexRepository` 实例**再 load，否则命中内存缓存、磁盘上的旧文件根本没被读。

## 19. widget test 里 await 真实 I/O = 挂死（不是假失败）

`await AppPaths.init(...)` / `await state.load()` 这类**真实 I/O**直接写在
`testWidgets` 的测试体里，**会挂死**（进程空转、测试永远不结束、看不到任何断言失败）——
因为假时钟不推进真实 I/O。必须放进 `tester.runAsync`：

```dart
final state = (await tester.runAsync(buildState))!;
```

判别方法：测试卡在第一条用例且**没有任何断言输出**，十有八九就是这个。
（`GOTCHAS.md` §14 讲的是「先断言后失败」的形态，这里是它的兄弟形态：直接挂死。）

## 20. widget test 里不能出现 InkSparkle（运行时着色器只编了 Vulkan stage）

**症状**：任何「点了按钮」的 widget test 都会炸：

```text
Asset 'shaders/ink_sparkle.frag' does not contain appropriate runtime stage
data for current backend (SkSL). Found stages: Vulkan
```

**根因**（不是环境问题，是这条工具链的必然结果）：

1. widget test 里 `defaultTargetPlatform == android`（`FLUTTER_TEST` 环境变量强制，
   见 `flutter/lib/src/foundation/_platform_io.dart`）→ `ThemeData` 默认用
   `InkSparkle.splashFactory`（`theme_data.dart`：`useInkSparkle = android`）；
2. `InkSparkle` 画墨水动画时要加载运行时着色器 `shaders/ink_sparkle.frag`；
3. **测试**资源包把这个着色器按 `TargetPlatform.tester` 编译
   （`flutter_tools/.../shader_compiler.dart`：`--sksl --runtime-stage-vulkan` +
   `--iplr`）→ 产物里只有 **Vulkan** stage；
4. `flutter_tester` 默认走 `--enable-software-rendering`（Skia / **SkSL** 后端）
   → 引擎拒绝加载 → 抛异常。

**修法（已实施）**：测试统一用 `InkRipple`（不需要运行时着色器）——
`test/helpers/test_theme.dart` 的 `testTheme()`，所有测试的 `MaterialApp` 都传
`theme: testTheme()`。

**别再走的歪路**：

- ❌ 在 `test/flutter_test_config.dart` 里设 `debugDefaultTargetPlatformOverride`
  → flutter_test 的不变量检查会报
  「The value of a foundation debug variable was changed by the test」（每个用例都炸）。
- ❌ 以为「只有这台机器坏了」→ 用户机器上同样复现（用的是同一条工具链）。
- ✅ 真 app 不受影响：真机/桌面包按目标平台编译着色器，`InkSparkle` 正常加载。

## 21. 笔记编辑区（面板）的三个坑

- **面板可能被直接当 `MaterialApp.home`**（测试里很常见）→ 没有 Scaffold 就没有
  Material → 面板里的 `InkWell` 抛「No Material widget found」，还会连带把
  `Row` 撑成「overflowed by 299348 pixels」（ErrorWidget 的固有宽度，数字很唬人）。
  → `NotesPanel` 自己套一层 `Material(color: Colors.transparent)`。
- **分隔条的拖动方向**：分隔条在编辑区**上方**，往下拖 = 编辑区变矮（比例变小），
  往上拖 = 变高。比例公式是 `ratio - delta.dy / totalHeight`（`delta.dy` 向下为正）。
- **等真实 I/O 的用例在并发下会偶发超时**：全量 `flutter test` 时机器负载高，
  「停写 800ms 后落盘」「新建笔记后打开」这类用例会超时，但单独跑必绿。
  → 等待预算给足（轮数 ≥ 80、真实延时 20ms），别按「单跑能过」的标准写。

## 22. AI 写回笔记的三条纪律

1. **必过 diff**：任何 AI 对正文的修改都要先弹 diff（接受/拒绝），接受后写进
   **编辑器缓冲**（不是直接落盘），落盘仍走自动保存。`Ctrl+Z` 能撤销（Flutter 的
   `UndoHistory` 会记录 `controller.value` 的每一次变化，所以直接改 value 也进历史）。
2. **只允许一个请求在跑**；取消用 `llm.CancelToken`，取消后**不写回任何内容**
   （流式中途取消会得到空结果 → `StateError('模型未返回有效内容')`）。
3. **上下文裁剪要有提示**：正文超过 `notes_context_char_limit`（默认 12000）时
   降级为「大纲 + 选区 + 命中关键词段落」，并把 `truncated=true` 传给界面提示，
   同时提供「包含全文」强制开关。

配套的易错点：
- `StateError` 在 Dart 里是 `Error` **不是** `Exception` → 测试里写
  `throwsA(isA<Exception>())` 会漏；用 `throwsA(anything)`。
- widget test 里断言「编辑区没了」要用
  `find.descendant(of: find.byKey(Key('note-editor')), matching: find.byType(TextField))`
  —— AI 边栏里也有 `TextField`，直接 `find.byType(TextField)` 会多匹配。

## 23. 移动端笔记（底部 Tab / AI 抽屉 / 全屏 diff）

- **`DraggableScrollableSheet` 的"上拉"只挂在滚动视图上**：它给 builder 的
  `scrollController` 必须真的传给里面的 `ListView`，否则拖拽完全没反应。
  → `NoteAiPanel` 加了可选 `scrollController`，抽屉把 sheet 的控制器透传给对话流
  （`_listScroll`）。头部的拖拽条只是视觉提示，不承担手势。
- **`showModalBottomSheet` 里的 `context` 是 sheet 自己的路由上下文**：抽屉内的
  `Navigator.of(context).pop()` 关的是抽屉（不会关掉编辑页）—— 关闭按钮就是靠这个。
- **AI 面板在抽屉里要 `sheet: true`**：展开态宽度是硬编码 320，不撑满会在窄屏留白；
  同时要换掉「收起」按钮（抽屉的收起 = 关闭），否则语义重复。
- **按 `MediaQuery` 宽度分叉的弹层，widget test 默认会走窄屏分支**：测试默认
  逻辑尺寸是 800×600，`showNoteDiffDialog` 的阈值是 `< 820` → 断言里不能再指望
  `find.byType(Dialog)`；要覆盖桌面分支需自己把 `tester.view.physicalSize` 调大。
- **窄屏 `_Sidebar` 必须 `compact: true`**：否则侧栏内分段 Tab 与底部 Tab 同时存在
  （双入口，违反 D9），测试里 `find.text('会话')` 会 `findsNWidgets(2)`。
- **AI 强制竖轨只用于桌面**：`NotesPanel.mobile` 分支直接不渲染边栏，别把
  `< 1080 → locked` 的判断套到移动端（移动端整页才 400dp 宽，会永远是竖轨）。

## 24. 外部 md 文件（只读 / 写回 / 平台）

- **UTF-8 解码器会自己吃掉 BOM**：`utf8.decode` 返回的字符串里**没有** U+FEFF，
  所以「`text.codeUnitAt(0) == 0xFEFF`」永远为假。BOM 只能按**字节**判断
  （`EF BB BF` 前缀），写回时再补回去。CRLF 同理：读时统一成 `\n`（否则 TextField
  会把 `\r` 当普通字符显示），写回时按原文件的 `crlf` 标记换回去。
- **`file_picker` 在 Android / iOS 常返回缓存目录里的副本**（`getTemporaryDirectory()`
  下），往那儿写回去不会影响用户的原始文件。`ExternalDocRepository.read` 用
  `isTransientCopyPath` 标记 `writable = false`，UI 必须禁用「开启编辑」。
  单元测试里注入 `ExternalDocRepository(cacheDir: '')` 以免依赖 path_provider 插件。
- **侧栏顶行只有 288px，别再加按钮**：`AppTheme.sidebarWidth` = 288，
  `_Sidebar._brandRow` = 徽标 + ☰更多 + 标题 + 审批/模板/刷新/新建/回家，按钮统一
  28×28（iconSize 17、`constraints: tightFor`）、彼此用 `_brandRowGap`(6) 隔开，
  标题用 `Expanded(Text(…ellipsis))` 吃掉剩余宽度。再加第 7 个按钮就得复用
  这个宽度（「打开外部 md」就是这样被挪进「更多」菜单的）。图标按钮默认最小 48px，
  不显式收紧必 `RenderFlex overflowed`。
- **笔记列表的空态不能整列替换**：外部文件区在列表最上方，用 `Center` 空态卡片替换
  整列会让「打开 md 文件 / 打开文件夹」入口一起消失。空态改成列表内的软提示
  （`_emptyHint`）。

## 25. GitCode Release 上传（`dist/gitcode_release.sh`）

- **`upload_url` 是短时效预签名地址，只能一次性用**：PUT 失败后再拿同一个 URL 重试
  必然还是失败。重试必须**每轮重新 GET `releases/:tag/upload_url`**。
- **`RELEASE_JSON` 是快照，不能用来判"已存在"**：脚本开头取的那份在重试时已经过期，
  会误判成「还没传」而重传。`upload_with_retry` 每轮先 `refresh_release` 再判。
- **curl 退出码 0 不等于文件落地**：OBS 带 `x-obs-callback` 时常见「对象已落地但回调
  超时回 5xx」，所以 2xx 之后还要 `refresh_release` + 核验 `.assets[].name`。
- **单文件失败不要 `exit`**：`set -e` 下原写法会让后面所有附件都不传。改成收集
  `FAILED` 数组、结尾汇总 + `exit 1`，重跑靠「已存在则跳过」幂等补齐。
- **跨 runner 没有共享文件系统**：脚本里加 `flock` / 全局锁对三个并行 workflow 无效；
  跨 runner 的串行只能靠 workflow 拓扑（`needs` / 单一 publish job），
  且**不要**用跨 workflow 的 `concurrency` 组——每组只允许 1 运行 + 1 等待，
  后到的等待者会顶掉前一个（静默丢一个平台的产物）。

## 26. Release 流水线（构建并行 / GitHub 并行 / GitCode 串行）

- **`.github/workflows/publish-gitcode.yml` 是 GitCode Release 的唯一发布者**。三个
  `build-*.yml` 里那个 `Attach to GitCode release (manual only)` step 只在
  `workflow_dispatch` 且填了 `gitcode_tag` 时跑（单路，无所谓串行）；tag 推送路径
  一律交给 publish workflow。
- **跨 workflow 没有 `needs`**，只能用 `workflow_run`。于是：它会被 3 个 build 各触发
  一次 → 用 workflow 级 `concurrency` 组（key = tag）串行；**等待位只有 1 个，后到的
  会顶掉先到的**，这在本设计里无害（每次运行都补齐"当时已就绪"的全部产物，最后一次
  一定看到 3 个 artifact）。反之，**不要把 `concurrency` 用在三个 build workflow 上**，
  那会真的丢产物。
- **`workflow_run` 只认默认分支（main）上的 workflow 定义**：新增/改这条流水线后必须
  合到 main 才生效，光推 tag 不生效。
- **`gh run list --branch <tag>` 不可靠**：tag 触发的 run 用 branch 过滤常常查不到。
  改成 `--limit 30 --json headBranch` 后按 `headBranch == TAG` 在 `--jq` 里筛。
- **artifact 下载后是 `<artifact名>/<文件>` 两层**，且发布 workflow 里不能把产物解到
  `dist/`（那目录装的是构建脚本，`dist/*` 会把 `.sh` 一起传上去）→ 解到 `_dl/`，
  `find _dl -mindepth 2 -type f -exec mv -f {} out/` 展平，再传 `out/*`。

## 27. Android 剪贴板：`Clipboard.getData` 会被**逐应用权限**挡掉

- 症状极具迷惑性：**整个 app 里所有输入框**长按 → 选「Paste」→ 什么都没发生（一个字也不进框）；
  自造粘贴按钮拿到的是**非 null 的 `ClipboardData` 但 `text` 为空串**，看上去像"剪贴板是空的"。
- 真因（2026-11-05 本机实测）：系统里 **XChat 的「读取剪贴板」权限被禁用**。放开后
  Base URL / API Key 立刻都能长按粘贴。
- 两条路径**不是一回事**，排查时别混：
  - 应用内/Flutter 自绘工具栏的「粘贴」→ `EditableTextState.pasteText` → `Clipboard.getData`
    → **受逐应用权限/ROM 隐私策略限制**；拿到空文本时框架静默把选区替换成空串，
    所以"点了没反应"。
  - 键盘/输入法自己的「粘贴」→ IME 通过 `InputConnection.commitText` 提交 → **不受该限制**。
    但**密码框（`obscureText: true`）里多数 IME 不显示剪贴板条**，用户往往碰不到这条路。
- 判定法：同一个剪贴板内容，在**另一个 Flutter app** 里长按 Paste 能贴、在本 app 不能 →
  就是逐应用权限，不是 Flutter 版本，也不是 `obscureText`/`autocorrect`/按钮实现/容器
  （`Scaffold+ListView` vs `AlertDialog`）的任何差异。
- 关掉这个坑的唯一可靠做法：**提示文案要指向权限**，不要写「剪贴板为空」；
  排查时先在一个普通明文框（不是密码框）试粘贴，能区分"字段问题"还是"应用级权限问题"。

## 28. Android 转后台会掐断 LLM 流（不是网络库的锅）

- 症状：转后台再回来，回答停在半截 / 状态条出现 `TransportException … SocketException`，
  有时恰好是「`No data received for 120s (stream stalled)`」。
- 真因是**进程**而不是连接：Activity 进 cached 后会被 cached-app freezer 冻结、被 LMK
  回收、被 Doze 断网、被国产 ROM 秒杀。整个 turn 是进程内一个 `dart:io` SSE 流
  （`IoHttpTransport`），进程没了连接就没了。
- 三条必须记住的机制：
  1. `HttpLlmProvider._sendWithRetry` **只在首字节前**重试（出了内容再重试会重复输出）
     → 中途断必然向上抛，靠 `AgentEngine` 的兜底，不要指望重试。
  2. `Stream.timeout` 的计时器在进程冻结期间不走，解冻瞬间一次性到期 → 会**误报**
     stalled。所以 watchdog 走 `ActivityClock.activeSince`（前台时间），别改回
     `source.timeout(...)`。
  3. `ForegroundServiceStartNotAllowedException`（Android 12+ 从后台启动 FGS）只能
     catch 掉：保活失败不影响本进程内的 turn，别把它当致命错误。
- 判定法：`adb logcat | grep -iE 'lowmemorykiller|am_kill|Freezer'`；把电池优化关掉后
  是否还断；屏幕常亮放前台是否不断。
- 用户侧唯一有效设置：允许本应用后台运行 / 关闭电池优化（Android 13+ 还要允许通知，
  否则前台服务的通知不显示，但服务仍然在跑）。
