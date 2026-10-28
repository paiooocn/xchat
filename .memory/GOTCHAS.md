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
