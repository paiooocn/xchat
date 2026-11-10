# XChat 架构速览（索引层）

> 本文只写**结构与不变量**。设计动机见 `DESIGN.md`，功能清单见 `FEATURES.md`。
> 文件级事实见 `MAP.yaml`，职责与风险见 `ANNOTATIONS.yaml`。

## 1. 分层与依赖方向

```
  ui.pages / ui.widgets / ui.theme        Flutter 界面
          │
  state   AppState · ApprovalCenter        全局状态 / 跨会话审批队列
          │
  session SessionController · SessionOps    单会话运行时（多会话并行）
          │
  agent   AgentEngine                       ReAct 主循环
          │                    │
  llm     OutboundAdapter · LlmFactory      出站适配 / provider 工厂
          │                    │
  agent.tools  BuiltinTools · PathGuard · WebView     pkg.llm_api（vendor LLM 客户端）
          │
  data    Session/Template/Config/Project/IndexRepository
          │
  data.xml  SessionXml · TemplateXml · ProjectXml · XmlOut
          │
  models  会话/消息/配置/provider/模板/项目（纯数据，无 Flutter 依赖）
          │
  core    AppPaths · app_version · json_utils · python_runtime
```

依赖方向自上而下。**唯一的反向引用**：`core` 的两个文件用了模型类型
（`python_runtime.dart`→`ProxyConfig`、`window_prefs.dart`→`AppConfig`），
`models` 侧也有文件用到 `core` 的 JSON 工具 —— 这是底层良性环，不要再往上扩散。

## 2. 启动流程（`lib/main.dart`）

```
ensureInitialized
  → AppPaths.requestSharedAccess()   Android 申请共享存储权限
  → AppPaths.init()                  解析数据根目录（失败必须降级，不能抛）
  → 构造 IndexRepository + 4 个 Repository + AppState
  → state.load()                     读 config.json + index.json（try/catch 兜底）
  → 桌面端：恢复窗口尺寸（先 best-effort，首帧后再幂等重放一次）
  → runApp(Provider<AppState> → XChatApp)
```

**不变量**：`runApp` 之前任何异常都必须被吞掉并降级 —— 数据根目录坏了也要让用户进设置页换目录。

## 3. 一次 turn 的数据流

```
UI 发消息
  → SessionController.send()
  → AgentEngine.run(userText, attachments)
      ├ 写入 user 消息（附件落进 <sandbox>/attachments/）并持久化
      ├ BuiltinTools.build(...) → ToolRegistry（按会话开关裁剪工具）
      ├ createProvider(...)     → llm_api provider
      └ while 循环：
          ├ 出站：OutboundAdapter 把 Session.messages → llm_api ChatMessage
          │        （思考回发 + tool 协议修复）
          ├ 流式：ChatEvent → AgentEvent → UI（思考块/文本/工具调用块）
          ├ 工具调用 → 执行 → 结果回写为 tool 消息 → 下一轮
          └ 预算检查：累计轮次 ≥ toolCallsLimit → 追加一条续判 user 消息
  → 落盘：SessionRepository → XML（原子写）
  → 索引：IndexRepository 增量更新 index.json
```

## 4. 落盘布局

```
<root>/
  config.json                 全局配置
  sessions/<uuid>.xml         会话（根元素 chat，sandbox 属性记录工作目录）
  templates/                  会话模板
  notes/<id>.md               Markdown 笔记（front-matter + 正文）
  scripts/<id>.json           页面提取脚本
  projects/                   项目文件与工作目录
  logs/
  sandboxs/                   每会话工作目录
```

数据根目录：桌面 `~/Documents/XChat`；Android `/sdcard/com.yimo.xchat/data`（需共享存储权限）。

## 5. 跨层不变量（改代码前先确认自己没破坏）

1. **序列化只在 `data.xml`**：`models` 里不得出现任何 XML/JSON 拼装逻辑。
2. **UI 不直接碰文件系统**：一律经 `data` 层的 repository。
3. **全局状态只有一个**：`AppState`（`ChangeNotifier`），会话级状态在 `SessionController`。
4. **工具路径必须过 `PathGuard`**：`resolve` 拦 `..`，涉及真实读写用 `resolveReal` 追符号链接。
5. **出站消息必须满足 tool 协议**：`assistant.tool_calls` 后恰好一条对应 `tool` 消息。
6. **思考内容必须回发**：`reasoning_content` 与 `<think>` 两种形态都要发给模型。
7. **`index.json` 是缓存，磁盘是事实**：加载时校验，不一致就透明重建。
8. **controller 生命周期长于面板**：切换会话不 dispose，否则并行会话会被打断。
9. **用量口径固定**：单次写 assistant，累计写 system（含 context）。
10. **新字段必须能读旧文件**：会话 XML 是长期存档，格式只能加不能改语义。
11. **`task_id` 是显示维度，不是上下文维度**：任务式会话（`kind="task"`）里消息带
    `task_id`，但出站历史永远是整个会话（`buildChatMessages(session)`，方案 B）；
    `SessionOps.*OnlyTaskId` 只用于编辑/删除/滚动定位这类「改数据」的路径，
    而删改必须限定在同一任务的范围内（否则会误删别的任务的对话）。
12. **一手消息一手 taskId**：一次 turn 产生的 user/assistant/tool 消息由
    `AgentEngine` 统一打标（构造参数 `taskId`），别在别处补。
13. **项目归档是级联的**：归档/恢复项目会连带归档/恢复它名下**全部**会话
    （`AppState.setProjectArchived` → `_setSessionsArchivedOfProject`）。
    侧栏只列活动项目，所以「不级联」会让项目的会话在侧栏与归档页都看不到。
14. **删除项目连带删除会话**：`AppState.deleteProject` 删项目时**同时删掉它的
    全部会话**（XML + 索引 + 内存态），不再把会话「脱离项目」留下。调用方必须
    先做二次确认（`confirmDeleteProject`）。项目的工作目录不删，只重命名为
    `_rec_<原名>` 回收（`AppState._recycleSandbox`）。
15. **应用显示名只有一个来源**：`lib/core/app_brand.dart` 的 `kAppBrandName`
    （`String.fromEnvironment('APP_BRAND_NAME')`，默认 `XChat`）。界面文案读它；
    改名版靠**构建期**注入（`--dart-define=APP_BRAND_NAME=SixChat`），
    源码里不再出现硬编码的 "XChat"。**只改显示名**：applicationId / 包名 /
    数据目录一律不变（改名版与正式版是同一个应用）。原生侧（Android 启动器
    label、桌面窗口标题）不读 Dart 常量，各平台有各自的注入通道
    （Gradle `resValue` / CMake 编译宏），三处必须同值。
16. **笔记是左栏 Tab，不是独立路由**：笔记页是 `HomePage` 左栏「会话 | 笔记」的
    另一个 Tab，主区随 Tab 切换；**不新增路由**。笔记列表挂在 `AppState`
    （`notes` / `archivedNotes`，只存摘要，正文按需读取）。
17. **笔记用 Markdown 文件，不是 XML**：一篇笔记 = `<root>/notes/<id>.md`
    （front-matter + 正文），front-matter 的拼装/拆解只写在
    `lib/data/xml/note_md.dart`；正文**逐字保留**（写回时只重写 front-matter 块），
    未知 front-matter key 原样保留（不丢用户/外部工具写的数据）。
18. **AI 写回必过 diff**：任何 AI 对笔记正文的修改都要先进 diff 预览（接受/拒绝），
    接受后**先进编辑器缓冲**（可 Ctrl+Z），再走自动保存落盘 —— 不存在静默覆盖。
19. **笔记中间栏只有一套布局**：固定「上预览 / 下编辑」，没有「编辑/分屏/预览」
    模式切换；唯一的可调量是下区高度（三档 40/20/0，分隔条拖动吸附，**全局**
    存 `SharedPreferences`，不做 per-note 覆盖）。预览**必须**走
    `markdownView()`，不要另写渲染器。
20. **移动端只有底部 Tab 一个工作区入口**：窄屏（`< 820`）由 `HomePage` 的
    `bottomNavigationBar`（`会话｜笔记`）切换工作区，`_Sidebar(compact: true)`
    **不再渲染内部分段 Tab**（不做双入口）。笔记内部是栈：列表 →
    `_MobileNotePage`（`NotesPanel(mobile: true)`）→ AI 底部抽屉；
    `NotesPanel.mobile` 时**不渲染右侧 AI 边栏**，AI 走 `showModalBottomSheet`。
21. **窄窗口 AI 边栏强制竖轨**：窗口宽度 `< kNoteAiAutoCollapseWidth`（1080）时
    `NotesPanel` 传 `collapsed: true, locked: true`，展开按钮置灰 —— 避免
    侧栏 + 主区 + 320px AI 边栏在 820–1080 区间放不下。
22. **外部 md 文件只读、不写头、不进索引**：用户磁盘上的 `.md` 由
    `lib/data/external_doc_repository.dart` 读写 —— **不写 front-matter**、不进
    `index.json`，正文逐字读写（BOM / CRLF 按字节判断并原样还原）。默认**只读**，
    必须在 UI 上「开启编辑」（每文件每会话确认一次）后才允许写回原文件；
    保存前比对 mtime。`<root>/notes/` 内的文件一律按内部笔记打开
    （`AppState.internalNoteIdForPath`），避免同一文件两个真相。
23. **长连接在移动端要「保活 + 可续」**：一次 turn 全程是一个进程内 SSE 连接
    （`llm` → `IoHttpTransport`）。移动端后台会被冻结/回收，所以
    ① `AgentEngine.run` 用 `lib/core/keep_alive.dart`（Android 前台服务
    `TurnKeepAliveService`）护住进程，桌面/iOS 是 no-op；
    ② 流中断时 `AgentEngine` 把已生成内容写成 `incomplete="true"` 的 assistant 消息
    再报错（工具调用一律丢弃，否则破坏不变量 5），UI 据此显示「已中断」；
    ③ 空闲看门狗（`idleTimeout`）按**前台时间**计时（`lib/core/app_activity.dart`
    实现 `llm.ActivityClock`），后台挂起的时间不得计入，否则一回到前台就误报
    「stream stalled」。
24. **系统栏内边距只在 `XChatApp.builder` 预留一次**：Android（15+ edge-to-edge）
    会画到状态栏/导航栏底下。`lib/app.dart` 的 `builder` 用 `MediaQuery.padding`
    的 top/bottom 包一层 `Padding` + `MediaQuery.removePadding`，子页面因此
    **不需要**自己再躲状态栏；新增整屏页面时不要改回 `viewPadding`，也不要再加
    `Scaffold` 级别的手工偏移（会与这层叠加）。
25. **任务标注是消息上的数据，不是出站时算出来的**：任务式会话每条 user 消息的
    `【任务：…】` 落盘在 `SessionMessage.premark`（`<user><premark>`），文本的
    唯一出处是 `TaskItem.premark`，写入点只有 `AgentEngine.run` 与
    `SessionController.seedTaskMessage`（+ 续判的合成 user 消息）。**写入即冻结**
    ——任务改名不回改历史标注。展示层（`message_bubble`、编辑框、复制）**只读
    `content`**，不许把 premark 混进 UI。
    **标注跟着归属走**：删消息 / 删任务项（`Session.removeTask` 连带删其全部消息）
    时 `<premark>` 随消息一起从 XML 消失；出站层的 `premarkOf` 还做一次归属校验
    ——任务项不存在或 `task_id` 为空 → 一律不发标注（含已落盘的 premark）。
    旧存档没有该字段时回退按任务项当前标题派生，**只读、不迁移、不回写**文件。
26. **附件分三类，出站方式由 `AttachmentKind` 决定**：`image` → base64
    `image_url` part（受 `AppConfig.maxAttachmentBytes` 限制）；`text` → 原文内联成
    `<file name="…">…</file>` 的 `TextPart`（受 `kMaxTextAttachmentChars` 截断），
    **因此不需要会话开任何工具**；`file` → **不内联**，只发一条说明 + 沙箱相对路径，
    由 `read_file`/`shell` 去读（受 `AppConfig.maxFileAttachmentBytes` 限制）。
    体积上限按 kind 分成两个独立设置（图片走 base64 是传输上限，其他文件只落盘是
    磁盘上限）。分类只在 `lib/data/attachment_intake.dart` 一处做（拖拽与「附件」
    按钮共用），**不按类型拒绝文件**，只在超限/目录/读不了时拒绝；新增类型别在 UI 里
    另写分支。`docx/xlsx/pptx` 由 `lib/data/office_text.dart` 抽成文本，再按 `text`
    处理（落盘成 `.txt`，展示名仍是原文件名）。
27. **已在 sandbox 内的附件不再复制**：`AgentEngine._storeAttachments` 对
    `p.isWithin(session.sandbox, path)` 的文件**原地引用**（存绝对路径），其余才复制进
    `<sandbox>/attachments/`。判断必须用 `p.canonicalize` 归一化后的路径，别用
    `startsWith`（`/a/sbx2` 会被 `/a/sbx` 误判）。
