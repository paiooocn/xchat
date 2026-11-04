# STATE — 进度交接

> **每次会话结束前必须更新本文件。** 这是新会话唯一的"上次到哪了"来源。
> 格式保持：做了什么 / 改了什么文件 / 怎么验证 / 下一步 / 遗留问题。

## 2026-11-04 · M3 AI 助手（已实现）：改写 / 生成 / 问答 + diff 写回

**做了什么**（按 `docs/NOTES_IMPL_PLAN.md` §M3；不新增依赖）

- 新增 `lib/util/line_diff.dart`：**自己写的行级 LCS diff**（不引第三方依赖）。
  `diffLines(old, new)` → `DiffLine{type: equal/delete/insert, text, oldIndex, newIndex}`；
  先裁公共前后缀再做 LCS 表；表过大（> 400 万格）时退化为「全删 + 全增」；
  空文本按「没有行」处理（否则会多出一条空的删除行）。
- 新增 `lib/llm/note_assistant.dart`：
  - `buildNoteSystemPrompt` / `buildNoteUserPrompt`（按规划的 system+user 契约）；
  - `buildNoteContext`：**选区前后各 200 字**上下文；正文超过
    `notes_context_char_limit`（默认 12000）时降级为「大纲 + 选区 + 命中关键词段落」
    并置 `truncated`（界面据此提示「已按相关片段裁剪上下文」）；
    `forceFull` 对应界面上的「包含全文」开关。
  - `runNoteAssistant`（流式 + `llm.CancelToken` + 结果清洗）；
    带 `providerFactory` 注入点（测试用假 provider）。
  - `kNoteAiActions`：改写 7 个（润色/扩写/缩写/语气/翻译/纠错/格式）、
    生成 7 个（续写/摘要/标题/标签/大纲/纪要模板/复习卡片）、问答 1 个；
    温度：改写/纠错 0.3、生成 0.7、问答 0.2。
- 新增 `lib/ui/widgets/note_diff_dialog.dart`：`showNoteDiffDialog` ——
  宽 720 居中，红删/绿增 + 左侧竖条，未改行折叠成「省略 N 行」，
  底部 `[复制结果] [拒绝] [接受并应用]`。
- 新增 `lib/ui/widgets/note_ai_panel.dart`：AI 边栏两态 —— **展开 320px**
  （模型名 + 模型服务入口 + 收起按钮 / Tab「改写·生成·问答」/ 快捷动作 chips /
  对话流 / 输入区 + 「包含全文」开关 + 停止按钮），
  **收起 44px 竖轨**（AI 图标 + 生成中圆点 + 竖排「AI 助手」）。
  **生成中不允许收起**（收起按钮置灰）；未配 provider 时给引导文案（跳「模型服务」）。
- `lib/ui/widgets/note_editor.dart`：新增 `NoteEditorController`
  （读当前选区 / `replaceSelection` / `replaceAll` 写回**编辑器缓冲** → 走正常自动保存）。
- `lib/ui/pages/notes_panel.dart`：挂上 AI 边栏（右侧 320/44），顶栏的「收起 AI」
  与边栏里的收起按钮共用 `_toggleAi`；收起状态存 `SharedPreferences: notes_ai_collapsed`；
  **AI 结果一律先弹 diff**：接受后写进编辑器缓冲（`Ctrl+Z` 可撤销），
  拒绝则只关窗；「复制」类结果不改正文，只进剪贴板。

**改了什么文件**

- 新增：`lib/util/line_diff.dart`、`lib/llm/note_assistant.dart`、
  `lib/ui/widgets/note_diff_dialog.dart`、`lib/ui/widgets/note_ai_panel.dart`、
  `test/line_diff_test.dart`、`test/note_ai_test.dart`
- 改：`lib/ui/widgets/note_editor.dart`、`lib/ui/pages/notes_panel.dart`、
  `test/note_editor_test.dart`（编辑器输入框改用 `Key('note-editor')` 限定，
  否则会和 AI 边栏的输入框混淆）、`FEATURES.md`、`.memory/STATE.md`（本节）、
  `.memory/MAP.yaml`（生成器刷新）

**怎么验证**

- `flutter analyze lib test` → **No issues found**
- `flutter test test/line_diff_test.dart test/note_ai_test.dart` → **20/20 全绿**
  （diff：空输入/无变化/修改/新增/删除/整段替换/行序；
  prompt：system 带标题、user 带正文+请求+选区、选区前后 200 字、
  超限降级并带裁剪提示、「包含全文」强制全文、结果清洗；
  模型：流式收集、**中途取消 → 抛错不返回内容**、未配 provider 不请求；
  diff 弹层：接受=true / 拒绝=false；AI 面板：未配模型给引导文案、生成中不许收起；
  编辑器通道：读选区 + 写回缓冲）
- `flutter test`（全量）→ **390 passed, 1 skipped, 0 failed**
- `dart run tool/gen_memory_index.dart --check` → **OK**

**下一步**

- 进入 **M4（移动端 + 打磨）**：窄屏底部 Tab「会话｜笔记」（唯一工作区切换入口），
  笔记栈（列表 → 编辑 → AI 底部抽屉，高 70% 可上拉全屏）；
  深色走查；820–1080 窄区间 AI 边栏自动收起成竖轨；空态文案。

**遗留问题**

- 笔记页的 AI **临时切换模型**只做了「显示当前模型 + 跳模型服务页」，
  规划里的「本次临时换模型」下拉还没做（默认用 `AppState.appFeatureTarget`）。
- AI 的「问答」结果目前只能复制，不能一键「作为附录插入」（那会改正文，需走 diff）。
- 移动端还没接 AI 抽屉（M4）。

---

## 2026-11-04 · M2 笔记编辑区（已实现）：上预览 / 下编辑 + 三档高度 + 自动保存

**做了什么**（按 `docs/NOTES_IMPL_PLAN.md` §M2）

- 新增 `lib/ui/widgets/note_editor.dart`：
  - **上预览 / 下编辑**（唯一一套布局，不做模式切换）；预览走 `markdownView()`
    （GOTCHAS §8 的坑全部规避），改动后 **300ms 防抖**重渲。
  - **分隔条可拖动，拖完吸附到最近档位**（40% / 20% / 0%）；0% 档时编辑区与
    分隔条一起收起，预览占满。档位常量 `noteSplitRatios = [0, 0.2, 0.4]`。
  - **语法工具栏**：粗体/斜体/H1-H3/无序列表/任务列表/有序列表/代码块/行内码/
    链接/表格/引用/公式/图片；**有选区 → 包起来**（`**…**`、`*…*`、`` `…` ``…），
    **无选区 → 插入模板片段**（表格骨架、`![说明](图片路径)`…）。
  - `Ctrl+S`（`NoteSaveShortcut` + `NoteSaveIntent`）→ 手动保存。
  - `NoteSummaryTile`：列表行组件（标题 + preview + 置顶图标）。
- 重写 `lib/ui/pages/notes_panel.dart`（笔记主区）：
  - 顶栏：标题 / **40%·20%·收起** 三档按钮 / 「收起 AI」（M3 占位，先置灰）/
    ⋮ 菜单（重命名 · 编辑标签 · 置顶 · 归档 · 删除）。
  - 状态条：已保存 / 保存中… / 未保存 · 字数 · 标签 · 「保存」。
  - **自动保存：停写 800ms 落盘**（`Timer` 防抖）；`Ctrl+S` / 状态条按钮手动存。
  - **档位持久化**：`SharedPreferences` 键 `notes_editor_split_ratio`，值
    `40|20|0`（首次打开也落一次盘）。
  - **外部改动检测**：打开时记 mtime，保存前比对 → 变了就弹「磁盘上的笔记已变更」
    → 选「重新加载（丢弃本地）」/「保留本地（覆盖）」。
  - 「用编辑工具打开」走 `util/editor_launcher.dart` 的 `openInEditor`。
- 重写 `lib/ui/widgets/note_list.dart`（左栏列表）：搜索框 + **置顶 / 最近 /
  归档**分区 + 标签筛选 chips + 行菜单（重命名 · 标签 · 置顶 · 归档 · 删除）。
- `lib/models/app_config.dart`：新增 `notesContextCharLimit`
  （JSON `notes_context_char_limit`，默认 12000，供 M3 裁剪上下文用）。
- `lib/state/app_state.dart`：新增 `renameNote` / `setNoteTags` / `setNotePinned` /
  `noteModifiedAt`；`lib/data/note_repository.dart`：新增 `modifiedAt`。
- `lib/ui/pages/home_page.dart`：左栏笔记列表（`NoteList`）+ 主区（`NotesPanel`）接上。

**改了什么文件**

- 新增：`lib/ui/widgets/note_editor.dart`、`test/note_editor_test.dart`
- 改：`lib/ui/pages/notes_panel.dart`、`lib/ui/widgets/note_list.dart`、
  `lib/ui/pages/home_page.dart`、`lib/models/app_config.dart`、
  `lib/state/app_state.dart`、`lib/data/note_repository.dart`、
  `test/sidebar_tab_test.dart`、`test/template_max_tokens_test.dart`（等待窗口）、
  `FEATURES.md`、`.memory/STATE.md`（本节）、`.memory/MAP.yaml`（生成器刷新）

**怎么验证**

- `flutter analyze lib test` → **No issues found**
- `flutter test test/note_editor_test.dart` → **7/7 全绿**（预览渲染 Markdown、
  40% 可见 / 0% 收起、分隔条拖动吸附 0.2、粗体包选区、无选区插表格骨架、
  800ms 后自动落盘、档位写 `40/20/0`）
- `flutter test`（全量）→ **370 passed, 1 skipped, 0 failed**
- `dart run tool/gen_memory_index.dart --check` → **OK**

**踩坑**

- `NotesPanel` 里的 `InkWell`（档位按钮）报「No Material widget found」——
  面板可能被直接当 `MaterialApp.home` 用（没有 Scaffold）→ 面板自己套一层
  `Material(color: Colors.transparent)`。这个报错还会连带把 `Row` 撑成
  「overflowed by 299348 pixels」（ErrorWidget 的固有宽度）。
- 全量并发下，三个「等真实 I/O 落盘」的用例会**偶发超时**
  （`note_editor_test` 自动保存、`sidebar_tab_test` 新建笔记、
  `template_max_tokens_test` 保存）→ 单独跑必绿。已把等待预算加大
  （轮数 30→80、真实延时 10ms→20ms、sidebar 等待 10s→30s）。

**下一步**

- 进入 **M3（AI 助手）**：`lib/util/line_diff.dart`（行级 LCS，自己写）、
  `lib/llm/note_assistant.dart`（构造 prompt + 流式执行 + 上下文裁剪）、
  `lib/ui/widgets/note_ai_panel.dart`（展开 320 / 收起 44 竖轨）、
  `lib/ui/widgets/note_diff_dialog.dart`（diff 预览，接受后进编辑器缓冲）。
  默认用 `AppState.appFeatureTarget` 调模型。

**遗留问题**

- AI 边栏尚未实现（M3）；移动端底部 Tab（M4）。
- 笔记正文里的首行标题变化**不会**自动改 front-matter 的 `title`
  （当前只在重命名对话框里改）——是否要联动，留到 M3/M4 一起定。
- 下区高度档位是**全局**的（`SharedPreferences`），没做 per-note 覆盖（按拍板）。

---

## 2026-11-04 · M1 侧栏 Tab + 顶行按钮（已实现，纯 UI）

**做了什么**（按 `docs/NOTES_IMPL_PLAN.md` §M1；不碰存储层）

- `lib/ui/pages/home_page.dart`：
  - 新增私有枚举 `_WorkspaceTab { session, note }`；`_HomePageState` 加
    `_tab`（当前工作区 Tab）与 `_selectedNoteId`。
  - **左栏新增 Tab 行**（顶行下方、列表上方）：分段控件（`surfaceContainer` 底 +
    圆角 12），选中项白底 + 主色图标；切 Tab 时**左栏列表与主区同步换**
    （会话树 ↔ 笔记列表；聊天区 ↔ 笔记面板）。
  - **顶行改造（D7/D8）**：右侧依次 `↻ 刷新` → `＋ 新建`（primary 实心）→ `⌂ 回到首页`；
    「＋ 新建」会话 Tab = 新建会话、笔记 Tab = 新建笔记；
    **刷新按钮复用同一个 widget**，只按 Tab 换 tooltip（刷新会话列表 / 刷新笔记列表）
    与行为（`_refreshSessions` / `_refreshNotes`），刷新中的 spinner 逻辑沿用。
  - **删除「新建会话」行**：`_navEntries` / `_navList` / `_NavRow` 整块删掉，
    `_Sidebar` 的 `onNavigate` 参数与两个调用点一并删；`_navigate` 的死分支
    `case 'new':` 删除（`'new'` 只由 `_navEntries` 产生）。
  - 侧栏列表拆成 `_sessionList()`（原会话树内容）与 `_noteList()`（笔记列表）。
  - 笔记 Tab 的「＋新建」→ `AppState.createNote()` → 主区打开该笔记。
- 新增 `lib/ui/pages/notes_panel.dart`（笔记主区面板，**M1 为占位**，
  M2 填「上预览/下编辑」）、`lib/ui/widgets/note_list.dart`（左栏笔记列表，
  **M1 只落地空态/标题+preview 的简版**，M2 补搜索/置顶/最近/标签/归档与行菜单）。
- 未做：真 `Ctrl+N` / `Ctrl+Shift+N` 快捷键（按 D11 属**新增能力**，不在 M0–M4 范围）；
  移动端底部 Tab（M4）。

**改了什么文件**

- 改：`lib/ui/pages/home_page.dart`、`FEATURES.md`（§7.1、§9.1）、
  `.memory/STATE.md`（本节）
- 新增：`lib/ui/pages/notes_panel.dart`、`lib/ui/widgets/note_list.dart`、
  `test/sidebar_tab_test.dart`
- **未改**存储层（M0 的文件未动）

**怎么验证**

- `flutter analyze lib test` → **No issues found**
- `flutter test test/sidebar_tab_test.dart` → **6/6 全绿**
- `flutter test`（全量）→ **363 passed, 1 skipped, 0 failed**（含本轮修掉的着色器问题，
  见下「修掉的既有失败」）
- `dart run tool/gen_memory_index.dart --check` → **OK**（MAP.yaml 已刷新）
- 手工路径（未在本机跑）：点「笔记」Tab → 左栏出现笔记列表、主区出现笔记面板；
  顶行「＋」在笔记 Tab 建笔记；「新建会话」文字行已消失。

**修掉的既有失败（不是环境问题，已定位并修好）**

- 之前全量测试里长期有 9~10 条失败，报错都是
  `Asset 'shaders/ink_sparkle.frag' does not contain appropriate runtime stage data
  for current backend (SkSL). Found stages: Vulkan`。
  **根因**（见 GOTCHAS §20）：widget test 的 `defaultTargetPlatform` 是 android
  → `ThemeData` 默认用 `InkSparkle` → 要加载运行时着色器 `shaders/ink_sparkle.frag`；
  而**测试**资源包按 `TargetPlatform.tester` 只把它编译成 **Vulkan** stage，
  `flutter_tester` 却跑 SkSL 后端 → 引擎拒绝加载 → 凡是要画墨水动画的用例全炸。
- **修法**：新增 `test/helpers/test_theme.dart`（`testTheme()` = 默认主题 +
  `InkRipple.splashFactory`，不需要运行时着色器），13 个测试文件里的 17 处
  `MaterialApp` 全部改用它。**真 app 不受影响**（真机按目标平台编译着色器）。
- 试过但**走不通**的路：在 `test/flutter_test_config.dart` 里设
  `debugDefaultTargetPlatformOverride` → flutter_test 的不变量检查
  （`debugAssertAllFoundationVarsUnset`）会让**每个**用例报
  「The value of a foundation debug variable was changed by the test」。已放弃该文件。
- 副作用：这些用例的墨水动画从 sparkle 变成 ripple（仅测试环境）。

**踩坑（已记入 GOTCHAS）**

- widget test 里 `await AppPaths.init(...)` / `state.load()` 这类**真实 I/O 必须放进
  `tester.runAsync`** —— 直接 await 会**挂死**（假时钟不推进真实 I/O）。
  本轮第一次写测试就卡在这里（进程空转 4 分钟无输出），改用
  `final state = (await tester.runAsync(buildState))!;` 后正常。
  → GOTCHAS §14 已有的提醒，这里再补一条「挂死而不是假失败」的形态。

**下一步**

- 进入 **M2（笔记编辑区）**：`lib/ui/widgets/note_editor.dart`（上预览 / 下编辑 +
  分隔条拖动吸附 40%/20%/0% + 工具栏 + 300ms/800ms 防抖自动保存 + `Ctrl+S` +
  `SharedPreferences: notes_editor_split_ratio` + 外部改动 mtime 冲突弹窗）、
  扩写 `note_list.dart` 与 `notes_panel.dart`；新增 `test/note_editor_test.dart`。
  注意：预览**必须**走 `markdownView()`（GOTCHAS §8），公式走 `math_support.dart`。

**遗留问题**

- 笔记列表/编辑区/AI 边栏都还是占位（M2/M3 落地）。
- 移动端仍是「窄屏直接渲染侧栏」，底部 Tab 在 M4。
- `test/template_max_tokens_test.dart` 的「保存后落盘」用例在**全量并发**下偶发失败
  （单独跑必绿）——保存断言的等待窗口偏短，属于既有的时序脆弱点，未改。

---

## 2026-11-04 · M0 地基层（已实现）：Note 模型 / front-matter 序列化 / NoteRepository / 索引第五桶

**做了什么**（按 `docs/NOTES_IMPL_PLAN.md` §M0；**零 UI 改动**）

- 新增 `lib/models/note.dart`：`Note`（完整笔记：id/title/tags/created_at/updated_at/
  pinned/archived_at/body + `extra` 保留未知 front-matter key）、`NoteSummary`
  （列表摘要：无正文，有 preview）、`NoteIndexEntry`（index.json `notes` 桶的条目）。
- 新增 `lib/data/xml/note_md.dart`（**唯一**的笔记序列化处，纯字符串、无 IO）：
  `encodeNote` / `decodeNote` / `decodeNoteSummary` / `parseTags` / `previewFromBody` /
  `titleFromBody`；常量 `notePreviewLength = 80`、`noteHeadBytes = 4096`。
  规则：正文**逐字保留**（写回只重写 front-matter 块）；front-matter 与正文之间
  只吃掉**一个**空行；未知 key 原样保留；**裸 Markdown**（无 front-matter）按
  「无头笔记」导入（标题取正文首个 `# ` 标题），不报错。
- 新增 `lib/data/note_repository.dart`：读写 `<root>/notes/<id>.md`、tmp+rename 原子写
  （含 Windows 回落）、列表走索引（不读正文）、`read` 按需读正文。
- 改 `lib/core/app_paths.dart`：`notesDir` / `noteFile(id)`，`ensureDirs()` 加 `notesDir`。
- 改 `lib/models/catalog_index.dart`：加 `notes` 桶 + `allNoteIds`，
  **`version` 4 → 5**（旧索引被丢弃重建，既有机制）。
- 改 `lib/data/index_repository.dart`：`rebuild()` 扫 `notes/`（**只读文件头 4KB** 解析
  front-matter；头部没闭合 `---` 时回退读全文）、`_matchesDisk()` 增加 notes id 集合比对、
  新增 `upsertNote` / `removeNote`。
- 改 `lib/state/app_state.dart`：`notes` / `archivedNotes`（`List<NoteSummary>`）、
  `refreshNotes()`、`createNote()` / `readNote()` / `saveNote()` / `setNoteArchived()` /
  `deleteNote()`；`load()` 里调用 `refreshNotes()`；`indexRepository` 改 `late final`，
  `noteRepository` 与它共用同一实例（否则两边索引不是一份）。

**与计划的偏差（2 处，均已在实现中确认并按更贴规范的做法取）**

1. 计划写 `AppState.notes: List<Note>` —— 实现用 `List<NoteSummary>`：列表带元数据、
   正文懒加载是既有约定（会话同理），否则每篇笔记的正文都会被读进内存。
2. `NoteIndexEntry` 放在 `lib/models/note.dart`（而不是 `catalog_index.dart`）：
   让笔记特性的模型自成一个文件，catalog_index 只 import 它。

**改了什么文件**

- 新增：`lib/models/note.dart`、`lib/data/xml/note_md.dart`、`lib/data/note_repository.dart`、
  `test/note_storage_test.dart`
- 改：`lib/core/app_paths.dart`、`lib/models/catalog_index.dart`、
  `lib/data/index_repository.dart`、`lib/state/app_state.dart`、
  `test/task_session_test.dart`（`expect(CatalogIndex.version, 4)` → **5**）、
  `FEATURES.md`（§1.1 / §1.5 / §2 / 新增 §7.1）、
  `.memory/ARCHITECTURE.md`（新增不变量 16–18 + 落盘布局加 `notes/`）、
  `.memory/GOTCHAS.md`（新增 §18 笔记 front-matter 坑）、
  `.memory/ANNOTATIONS.yaml`（新增 `features[].notes`、更新 `data` / `data.xml` 职责）、
  `.memory/MAP.yaml`（生成器刷新）

**怎么验证**

- `flutter analyze lib test` → **No issues found**
- `flutter test test/note_storage_test.dart` → **15/15 全绿**（front-matter 往返、
  正文逐字相等、未知 key 保留、缺 key 走默认、裸 Markdown 导入、归档时间、
  仓库 CRUD、原子写无 `.tmp` 残留、4KB 头部扫描、index.json 出现 notes 桶且
  version=5、v4 旧索引被丢弃重建、索引损坏重建、外部新增笔记被校验发现、
  索引条目 JSON 往返、AppState 集成）
- `flutter test`（全量）→ **345 passed, 1 skipped, 9 failed**
- `dart run tool/gen_memory_index.dart --check` → **OK**（MAP.yaml 已用生成器刷新）
- ⚠️ 那 9 个失败是**环境性既有失败**，与本轮改动无关：`git stash` 后在干净树上跑
  同样是 9 个，报错均为
  `Asset 'shaders/ink_sparkle.frag' does not contain appropriate runtime stage data
  for current backend (SkSL). Found stages: Vulkan`
  （涉及 archive_page / home_flow / home_template_dialog / project_dialog /
  provider_max_output / session_wizard_prompt / task_session_flow /
  template_max_tokens / template_default）。**需要用户在正常环境复跑确认全绿。**
  （本轮唯一新增的真失败是 `test/task_session_test.dart` 断言了旧的
  `CatalogIndex.version == 4`，已随版本递增改为 5。）

**下一步**

- 进入 **M1（纯 UI）**：左栏「会话 | 笔记」Tab、顶行「↻ 刷新 / ＋ 新建 / ⌂ 回家」、
  移除「新建会话」行（连带删 `_navEntries` / `_navList` / `_NavRow` 与
  `_navigate` 的死分支 `case 'new':`）、刷新按钮按 Tab 复用同一 widget；
  新增 `test/sidebar_tab_test.dart`，并保持 `test/home_flow_test.dart` 不回归。

**遗留问题**

- 笔记的 UI（列表 / 编辑区 / AI 边栏）尚未存在，M0 只有存储层。
- `notes` 桶里归档笔记与活动笔记同桶（用 `archived_at` 区分），与「会话分两桶」的
  做法不同 —— 已在 `FEATURES.md §1.5` 注明。
- 上下文裁剪阈值（`notes_context_char_limit`）与下区高度档位
  （`SharedPreferences: notes_editor_split_ratio`）都还没接，M2/M3 再落。
- 那 9 个环境性 widget 测试失败未解决（与笔记无关）。

---

## 2026-11-03 · 实施规划（未实现）：新增 docs/NOTES_IMPL_PLAN.md + 两点拍板落定

**做了什么**

- 用户拍板两个悬置项：
  - **#4 移动端不保留双入口** —— 底部 Tab「会话｜笔记」是唯一工作区切换，
    不再同时提供抽屉入口。
  - **#5 刷新按钮复用** —— 同一个 widget 复用，按 Tab 只换 tooltip 与行为
    （会话列表 / 笔记列表）。
- 新增 **`docs/NOTES_IMPL_PLAN.md`**（实施规划，约 490 行）：让新会话照着做。
  内容：10 条已拍板决策（含本轮两条 + 新增 D11）、现状代码锚点表（真实符号名）、
  跨层不变量与已知坑提醒、**M0→M4 五阶段**（每阶段：目标 / 新增改文件 /
  数据契约 / 实现要点 / 测试 / 验收）、文件总表、文档与记忆索引收尾清单、
  验证口径、风险清单、**新会话开场对话提示词**（可直接复制）。
- 顺带修正一处**事实错误**（规划与设计稿里都曾按「Ctrl+N 是真快捷键」写）：
  全仓检索后确认 `Ctrl+N` **只是 `_navEntries` 里的文案标签**，
  没有任何 `Shortcuts`/`CallbackAction` 绑定（`Shortcuts` 只出现在
  `lib/ui/widgets/input_area.dart`，管 Enter/换行）。
  → 设计稿与规划都改为如实描述；「真快捷键」被降级为**新增能力**（单列任务）。
  同时补记：删 `_navEntries` 后 `_navigate` 的 `case 'new':` 变死代码，需一并删。

**改了什么文件**

- 新增：`docs/NOTES_IMPL_PLAN.md`
- 改：`docs/NOTES_AI_DESIGN.md`（§5.1.1 快捷键表述纠正）
- 改：`docs/mockups/notes_ui.html`（新建会话按钮 tooltip 去掉 `Ctrl+N`）
- 改：`.memory/STATE.md`（本节）
- **未改任何 `lib/` 代码**

**怎么验证**

- 规划里引用的代码位置逐条核对过真实源码：`_Sidebar` / `_brandRow` / `_navList` /
  `_navEntries` / `_NavRow` / `_navigate` / `_sessionArea` / `_MobileChatPage` /
  `markdownView` / `prompt_assistant._stream` / `appFeatureTarget` /
  `CatalogIndex.version` / `AppPaths.ensureDirs` / `SessionRepository._writeAtomic` /
  `TemplateRepository` / `confirmDelete` / `AppTheme` / `AppFonts`。
- 确认 `_NavRow` 仅被 `_navList` 使用；确认 `'new'` id 仅由 `_navEntries` 产生。
- 本轮**未跑** `flutter analyze` / `flutter test`（无代码改动）。

**下一步**

- 实施按 `docs/NOTES_IMPL_PLAN.md` 的 M0→M4 推进；每阶段独立提交、独立验证、
  独立更新 `.memory/STATE.md`。
- 实施时用规划 §9 的「对话提示词」开场。

**遗留问题**

- 仍待拍板（规划里已给出最小取值，实施时按此走）：
  **①** 笔记是否支持内嵌图片附件（一期按「不做」）；
  **②** AI 上下文裁剪阈值是否可配（按 `config.json` 的
  `notes_context_char_limit`，默认 12000）；
  **③** 下区高度档位按笔记存还是全局存（按全局 `SharedPreferences`，
  不做 per-note 覆盖）。
- 规划里把「真 Ctrl+N / Ctrl+Shift+N 快捷键」列为**新增能力**，
  不在 M0–M4 范围内，需另行拍板是否要做。

---

## 2026-11-03 · 设计调整（未实现）：笔记栏与会话栏合并（侧栏 Tab）+ 顶行新建按钮

**做了什么**

- 用户提了两点 UI 修改，本轮**只改 UI 设计**（mockup + 设计文档），**零 Dart 代码改动**：
  1. **「笔记栏」与「会话栏」合并，用 Tab 切换** —— 笔记不再是独立路由/独立页面，
     而是 `HomePage` 左栏的一个 Tab（`会话 | 笔记`）。切 Tab 时**左栏列表与主区同步换**：
     会话 Tab = 会话树 + 聊天区；笔记 Tab = 笔记列表 + 上预览/下编辑 + AI 边栏。
     移动端同样对齐：底部 Tab 改为 `会话 | 笔记`，笔记内部是 列表→编辑→AI抽屉 的栈。
  2. **移除侧栏「新建会话」行**，改为**顶行图标按钮**，插到「刷新会话列表」**右侧**
     （primary 实心按钮）；笔记 Tab 下同位置变「＋ 新建笔记」。
     连带影响：`_navEntries` 快捷入口列表只剩一项 → 整行取消（见 `home_page.dart`
     的 `_navEntries` / `_navList` / `_brandRow`）。
- 上一轮定的「上预览/下编辑 + 下区高度三档 + AI 边栏可收起」**保持不变**，与本次合并叠加。

**改了什么文件**

- 改：`docs/mockups/notes_ui.html`
  - 画板① 重写为「合并后的工作区 · 侧栏 Tab 切换」：态A（会话 Tab，含聊天区 + 输入区
    的新样式 `.chat-main` / `.chat-scroll` / `.composer`）与态B（笔记 Tab）上下并列
  - 新增样式：`.side-tabs`（侧栏 Tab）、`.icon-btn.primary`、`.chat-*`、`.composer`
  - 侧栏顶行改造：品牌行右侧 = 刷新 / ＋新建 / 回家；删除「＋ 新建会话」虚线行
  - 移动端画板：底部 Tab 改 `会话 | 笔记`；列表页顶行加「＋ 新建笔记」；去掉重复的 FAB
  - 画板编号：①合并工作区 ②下区高度三档&AI收起态 ③diff弹层 ④移动端 ⑤交互流程
- 改：`docs/NOTES_AI_DESIGN.md`
  - §1 范围内补「与会话合并为同一工作区的两个侧栏 Tab」
  - §3 总体方案图重画（合并后的外壳 + 合并要点）
  - §5.1 改为「入口：与『会话』并列的侧栏 Tab」；新增 §5.1.1「侧栏顶行调整」
  - §5.2 改为「桌面（≥1080px）」，画出会话 Tab / 笔记 Tab 两个外壳对照
  - §5.3 移动端改为底部 Tab `会话 | 笔记` + 笔记内部栈
  - §8 M1/M4 分期项、§10 验收标准同步
- 改：`.memory/STATE.md`（本节）
- **未改任何 `lib/` 代码**

**怎么验证**

- headless Chromium 逐块渲染截图核对：合并工作区（态A/态B）、下区三档、AI 两态、
  diff 弹层、移动端三屏、交互流程，均正常。
- 期间修掉：AI 面板「模型」标签竖排换行（`white-space:nowrap` + select 限宽）；
  移动端「新建笔记」与 FAB 重复（去掉 FAB）。
- 本轮**未跑** `flutter analyze` / `flutter test`（无代码改动）。

**下一步**

- 等用户确认后再实现。实现要点（对应真实代码位置）：
  - `lib/ui/pages/home_page.dart` 的 `_Sidebar`：`_brandRow` 加新建按钮、删掉
    `_navEntries`/`_navList` 的「新建会话」行；加 Tab 行
  - `HomePage` 增加 `_workspaceTab` 状态（会话/笔记），左栏与主区按它切换
  - 笔记主区建议放 `lib/ui/pages/notes_panel.dart`（不新增路由）
  - 移动端底部 Tab 同步改为 `会话 | 笔记`

**遗留问题**

- 沿用前两轮的待拍板点：**①** 笔记是否支持内嵌图片附件；**②** 上下文超 12k 字
  自动裁剪的阈值是否可配；**③** 高度档位存 `SharedPreferences` 还是 front-matter。
- 新增待拍板点：**④** 移动端底部 Tab 改成 `会话|笔记` 后，原来的移动端会话入口
  （抽屉）是否保留双入口（底部 Tab + 抽屉）；**⑤** 笔记 Tab 下侧栏顶行的「刷新」
  是否复用同一个 widget 还是按 Tab 换语义。

---

## 2026-11-03 · 设计调整（未实现）：笔记 UI 改为「一套布局」+ 上下分屏 + AI 边栏可收起

**做了什么**

- 用户对上一轮设计稿提了三点 UI 修改，本轮**只改 UI 设计**（mockup + 设计文档），
  **零 Dart 代码改动**、不改版本号：
  1. 「编辑 / 分屏 / 预览」三选一 → **合并为一套**：中间栏固定为
     **上下分屏，上区预览 / 下区编辑**，不再做模式切换；
  2. 下区（编辑区）高度可选 **40% / 20% / 0%**（0% = 收起编辑区，全宽预览）；
  3. AI 边栏要能 **收缩 / 展开**。
- 设计取舍（写进文档）：
  - 中栏只留一个心智模型（预览永远在上、编辑永远在下），用户只调「下区多高」这一个量；
  - 分隔条**可拖动**，拖动结果**吸附到最近档位**（40/20/0），保证持久化值只有三个；
  - 档位**按笔记持久化**（`SharedPreferences` 或 front-matter 扩展字段）；
  - AI 边栏：展开 320px / 收起 **44px 竖轨**（保留 AI 图标 + 「生成中」角标 + 竖排文字），
    收起时笔记区横向扩展占回 320px；**生成中不允许收起**（或收起后角标继续跑完）。
  - 移动端与桌面**同一套上下分屏**，只是 AI 侧栏换成底部抽屉。
- mockup 画板重构为 5 块：①桌面三栏（上下分屏）②**下区高度三档 & AI 边栏收起态**
  ③AI diff 弹层 ④移动端 ⑤交互流程。

**改了什么文件**

- 改：`docs/mockups/notes_ui.html`（布局重构：`.ed-prev`/`.ed-splitter`/`.ed-src` +
  `.editor.h20/.h0` 高度档位类；`.ai.collapsed` 44px 竖轨态；AppBar 段控换成
  「40%/20%/收起」；新增画板②；手机端编辑页改上下分屏）
- 改：`docs/NOTES_AI_DESIGN.md`（§3 总体方案图、§5.2/5.2.2/5.2.3、§5.3 移动端、
  §8 M2 分期项）
- 改：`.memory/STATE.md`（本节）
- **未改任何 `lib/` 代码**

**怎么验证**

- 用 headless Chromium（`~/.cache/ms-playwright/chromium-1228`）把 mockup 逐块
  渲染截图核对：主画板（上下分屏 + 40% 档）、画板②（三档 + AI 两态）、
  移动端三屏、交互流程，均正常；期间修掉了两个问题（编辑区 div 未闭合导致布局错位；
  手机端标题被档位控件挤没 → 改为 AppBar 图标按钮 + 状态条显示「编辑区 40%」）。
- 本轮**未跑** `flutter analyze` / `flutter test`（无代码改动）。

**下一步**

- 等用户确认这版 UI 后再进入实现；实现时按 M1 存储与列表 → M2 编辑器与预览
  （上下分屏 + 高度三档 + 拖动吸附）→ M3 AI 助手 → M4 集成与移动端。
- 实现要点提醒（来自本轮设计）：`markdownView()` 复用不变；预览在上编辑在下；
  高度吸附档位；AI 收起态用 44px 竖轨且生成中不收起。

**遗留问题**

- 上一轮留的两个待拍板点仍未决：**①** 笔记是否支持内嵌图片附件；
  **②** 上下文超 12k 字自动裁剪的阈值是否可配。
- 新增一个实现期待定项：高度档位存 `SharedPreferences` 还是 front-matter 扩展字段
  （文档里两者都写了，实现时二选一）。

---

## 2026-11-03 · 设计（未实现）：带 AI 助手的 Markdown 笔记

**做了什么**

- 需求：结合项目**已有的 Markdown 渲染能力**，设计一个带 AI 助手的 Markdown 笔记
  功能。**只出功能设计与 UI 设计图，不做实现**（本轮零 Dart 代码改动）。
- 盘点可复用点（决定设计方案的依据）：
  - `lib/ui/widgets/markdown_view.dart` 的 `markdownView()` —— 已封装代码高亮、
    行内码、引用、表格（`FlexColumnWidth`）、KaTeX 公式、选中复制保换行；
    **笔记预览直接调用它，不重写渲染器**（否则 `GOTCHAS.md` §8 的坑会全部复现）。
  - `lib/ui/widgets/math_support.dart` —— 公式语法随预览自动生效。
  - `lib/llm/prompt_assistant.dart` —— 应用级 LLM 调用的现成范式
    （`createProvider` → `provider.stream` → `onProgress` 增量 → `_unwrap` 去围栏）。
  - `lib/state/app_state.dart` 的 `appFeatureTarget` —— 笔记 AI 默认用「模型服务」页
    选的应用功能调用模型。
  - `lib/data/index_repository.dart` + `lib/models/catalog_index.dart` —— 索引缓存
    （笔记加第 5 个桶，`CatalogIndex.version` 4 → 5）。
  - `lib/ui/widgets/confirm_dialog.dart` —— 删除确认交互复用。
- 存储方案：**Markdown 文件 + front-matter**（`<root>/notes/<id>.md`），
  不是会话那套 XML —— 产物要给人读/给外部工具读，`.md` 可被外部编辑器、git、
  grep 直接消费；元数据用固定白名单 key 的 front-matter 承载。
- AI 助手三组能力：**改写**（选区/全文，产出替换文本）/ **生成**（摘要、大纲、
  标题、标签、待办骨架、复习卡片）/ **问答**（只读，基于笔记上下文）。
- **写回纪律**：任何 AI 对正文的修改都必须先过「diff 预览弹层 → 接受/拒绝」，
  接受后先进编辑器缓冲（可 `Ctrl+Z`），再走自动保存 —— 不存在静默覆盖。
- UI 设计（HTML mockup，4 块画板）：①桌面三栏（笔记列表 240 / 编辑区 / AI 侧栏 320）
  ②AI 修改 diff 弹层 ③移动端三 Tab（列表 / 编辑 / AI 底部抽屉）④交互流程。
  配色/圆角/字号沿用 `lib/ui/theme/app_theme.dart`；深浅色两套都做了。

**改了什么文件**

- 新增：`docs/NOTES_AI_DESIGN.md`（功能设计，约 400 行）
- 新增：`docs/mockups/notes_ui.html`（UI 设计图，单文件、零外部依赖、可直接浏览器打开）
- 改：`.memory/STATE.md`（本节）
- **未改任何 `lib/` 代码，未改版本号**

**怎么验证**

- 设计稿的 HTML 用 headless Chromium（`~/.cache/ms-playwright/chromium-1228`）
  渲染截图逐块核对过：桌面三栏、diff 弹层、移动端三块、深色模式均正常，
  工具栏/侧栏图标全部换成内联 SVG（emoji 在无字体环境会变成豆腐块）。
- 本轮**未跑** `flutter analyze` / `flutter test`（无代码改动，按约定不代跑）。

**下一步**

- 用户确认设计后再进入实现，建议按文档里的 M1→M4 分期：
  M1 存储与列表 → M2 编辑器与预览 → M3 AI 助手 → M4 集成与移动端打磨。
- 实现时先落 `lib/models/note.dart` + `lib/data/xml/note_md.dart`（序列化只在这层），
  再接 `NoteRepository` 与 `CatalogIndex` 第 5 桶（version 4 → 5）。

**遗留问题**

- 文档里留了两个待拍板点：**①** 笔记是否需要支持内嵌图片附件（一期只做纯 Markdown
  + 外部相对路径引用）；**②** 上下文超 12k 字时自动降级为「标题 + 大纲 + 选区 +
  关键词段落」的阈值是否可配（文档里写成可在设置里调）。
- 未做「笔记 ↔ 会话」双向集成（列为二期 M4/§7）。

---

## 2026-11-04 · 改名版打包：每次 build 多打一个「只改应用名」的 SixChat 版本

**做了什么**

- 需求：每次 build 时，除了正式版（XChat），再打一个**只改应用名字**的版本
  （XChat → SixChat），源码零改动。
- 做法：**构建期注入**显示名，代码里不再有硬编码的 "XChat"。
  - 新增 `lib/core/app_brand.dart`：`kAppBrandName` =
    `String.fromEnvironment('APP_BRAND_NAME', defaultValue: 'XChat')`（唯一来源），
    外加 `kAppBrandSlug`（产物文件名前缀）。
  - 界面文案改读它：`lib/app.dart`（MaterialApp title）、`lib/main.dart`
    （窗口标题）、`home_page.dart`（欢迎页文案 + 侧栏/底栏品牌行）、
    `settings_page.dart`（根目录 label + 关于页）、`font_test_page.dart`。
  - **Android 启动器名字**：`AndroidManifest.xml` 改 `android:label="@string/app_name"`；
    `android/app/build.gradle.kts` 从 flutter 传入的 `-Pdart-defines`（每项单独
    base64、"," 连接）解出 `APP_BRAND_NAME` → `resValue("string","app_name", …)`。
  - **桌面窗口标题**：CMake（linux/ 与 windows/）从环境变量 `APP_BRAND_NAME` 取值
    → 编译宏 `APP_BRAND_NAME`（Linux 窄串 / Windows 宽串）；
    `linux/runner/resources/com.yimo.xchat.desktop.in` 的 `Name=@APP_BRAND_NAME@`。
- **打包脚本**：三个脚本都在正式版之后多打一个改名版
  （`BRAND_VARIANT_NAME` 默认 `SixChat`，`BUILD_BRAND_VARIANT=0` 可关闭）：
  - `dist/build_apk.sh` → `dist/sixchat-vX.Y.Z.apk`
  - `dist/build_deb.sh` → `dist/sixchat-vX.Y.Z.deb`（脚本重构为 `build_deb` 函数，
    改名版构建前删 `build/linux`，强制 CMake 重新 configure）
  - `dist/build_windows.ps1` → `dist/sixchat-windows-x64-vX.Y.Z.zip`
- **CI**：三个工作流（android / linux-deb / windows）都把改名版产物一并上传 /
  附加到 Release；Windows 工作流改为直接调用 `dist/build_windows.ps1`
  （原来在 YAML 里内联打包，现在与本地同一条路径）。
- 文档：`docs/BRANDING.md`（新）、`FEATURES.md` §13、
  `.memory/ARCHITECTURE.md` 不变量 15、`.memory/GOTCHAS.md` §17。
- 版本：`0.6.12+1` → **`0.6.13+1`**（`pubspec.yaml` 与 `lib/core/app_version.dart` 同步）；
  applicationId / 包名 / 数据目录**没改**。

**改了什么文件**

- 新增：`lib/core/app_brand.dart`、`test/app_brand_test.dart`、`docs/BRANDING.md`
- 改：`lib/app.dart`、`lib/main.dart`、`lib/ui/pages/home_page.dart`、
  `lib/ui/pages/settings_page.dart`、`lib/ui/pages/font_test_page.dart`、
  `android/app/build.gradle.kts`、`android/app/src/main/AndroidManifest.xml`、
  `linux/CMakeLists.txt`、`linux/runner/CMakeLists.txt`、
  `linux/runner/my_application.cc`、`linux/runner/resources/com.yimo.xchat.desktop.in`、
  `windows/CMakeLists.txt`、`windows/runner/CMakeLists.txt`、`windows/runner/main.cpp`、
  `dist/build_apk.sh`、`dist/build_deb.sh`、`dist/build_windows.ps1`、
  `.github/workflows/build-android-apk.yml`、`.github/workflows/build-linux-deb.yml`、
  `.github/workflows/build-windows.yml`、`FEATURES.md`

**怎么验证**

- `flutter analyze lib test` → **No issues found**
- `flutter test` → **342 passed, 1 skipped**（337 + 新增 5 条品牌名守护用例）
- `flutter test --dart-define=APP_BRAND_NAME=SixChat test/app_brand_test.dart`
  → 默认名用例如期失败（Actual: 'SixChat'），证明 `--dart-define` 注入生效
- 新增用例 `test/app_brand_test.dart`：默认名 / Android `@string/app_name` +
  gradle 解 base64 / 界面读 `kAppBrandName` / 桌面原生宏 / 三个打包脚本都注入
- **构建脚本层面的验证**（没跑完整打包，只验证了「名字怎么传到各层」）：
  - Gradle：`cd android && ./gradlew --offline :app:help`（需 `JAVA_HOME=jdk17`）
    配置通过；临时打印验证：带 `-Pdart-defines=<base64(APP_BRAND_NAME=SixChat)>`
    → `appName=SixChat`，不带 → `appName=XChat`。
    （AGP 9 会报「defaultConfig contains custom resource values, but the feature
    is disabled」→ 必须在 `android { buildFeatures { resValues = true } }` 打开。）
  - CMake：`cmake -S linux -B build/cmtest`（不编译，只 configure）→
    `CXX_DEFINES` 含 `-DAPP_BRAND_NAME=\"SixChat\"`、`.desktop` 的 `Name=SixChat`；
    不设环境变量时是 `XChat`。
- **未实际编译打包**（按约定不代跑构建）：APK / deb / zip 的真机效果待用户验证

**发布（已执行）**

- 提交 `2457a9b`（release: v0.6.13）→ 打标签 `v0.6.13` → 已推送
  `origin/main` 与 `origin` 的标签。工作区干净。
- 推标签会触发三个 CI 工作流（android / linux-deb / windows），它们会**同时**
  产出 XChat 与 SixChat 两套产物并附加到 Release。
- 本轮按用户要求**未跑测试**（上一轮改动时已跑过：analyze 干净、342 passed）。

**下一步**

- 用户侧跑一次 `bash dist/build_apk.sh`，确认：
  ① `dist/sixchat-vX.Y.Z.apk` 生成；② 装到手机上启动器名字是 SixChat；
  ③ 界面里的品牌文案也是 SixChat；④ 与正式版 applicationId 相同（互相覆盖）。
- 可选后续：让改名版与正式版**可共存**（另开 applicationId / deb 包名 /
  数据目录）—— 改动面大，未做。

**遗留问题**

- 改名版与正式版**不能共存**（同 applicationId / 同包名 / 同数据目录），
  装谁覆盖谁。
- 品牌标记（侧边栏的「X」字形）与图标**没改**，改名版仍显示「X」标记；
  `windows/runner/Runner.rc` 里的 FileDescription/ProductName 仍是 "xchat"。
- Linux 正式版的窗口标题从 "xchat" 变成 "XChat"（与品牌名一致），属刻意的
  一致性调整。
- `flutter build linux` / `windows` 在改名版之前必须删构建目录，否则 CMake
  缓存里的显示名不变（脚本已代为删除）。
- **AGP 9 要显式开 `resValues`**：`defaultConfig { resValue(...) }` 会报
  「defaultConfig contains custom resource values, but the feature is disabled」，
  必须加 `android { buildFeatures { resValues = true } }`。

---

## 2026-11-04 · 修复：删除归档会话后归档页不刷新（只重建了活动列表）

**做了什么**

- 现象：归档页「归档·全局」删除会话后，行还在（重启应用才消失）。
- 根因：`AppState.deleteSession` 只调 `refreshSessions()`（重建**活动**列表），
  从没调 `refreshArchived()`；磁盘 index.json 其实已删干净（`removeSession` 会从
  `sessions` 与 `archived_sessions` 两个桶都删），所以重启后自愈。
  → 归档页读的是 `state.archivedSessions`（陈旧）→ 旧行一直显示。
- 修法（`lib/state/app_state.dart`）：
  - `deleteSession`：`await refreshArchived();` 放在 `await refreshSessions();` **之前**
    （顺序与 `setSessionArchived` 一致：先刷新归档列表，`_pruneCache` 才能用正确的
    归档集合裁剪缓存）；
  - `renameSession` / `setSessionTags`：同类问题（作用在归档会话上时，归档页显示旧
    标题/旧标签直到重启），一并改为同时刷新两个列表。
- 归档页「归档·项目」Tab 的子项删除走同一个 `deleteSession`，随本次一并修好。
- 未改版本号（0.6.12+1 不变），只发 `fix:` 提交。

**改了什么文件**

- `lib/state/app_state.dart`（`deleteSession` / `renameSession` / `setSessionTags`）
- `test/archive_page_test.dart`（新增 2 条回归用例）

**怎么验证**

- `flutter analyze lib test` → No issues found
- `flutter test` → **337 passed, 1 skipped**（335 + 新增 2）
- 新增用例：①「归档·全局」删除会话 ⇒ 行立即消失（修复前失败）；
  ②重命名归档会话 ⇒ 归档页标题立即更新。

**下一步**

- 无（等待真机确认即可）。

**遗留问题**

- 无。

---

## 2026-11-04 · 归档页重整（归档·全局 / 归档·项目）+ 项目归档级联 + 删项目连带删会话

**做了什么**（需求与拍板见文末「拍板记录」）

- 归档页（`lib/ui/pages/archive_page.dart`）从「归档会话 / 归档项目」两个平铺 Tab
  改成 **「归档·全局」/「归档·项目」**：
  - 归档·全局 = `projectId` 为空的归档会话（平铺，可恢复/删除）；
  - 归档·项目 = **父项=项目**（`ExpansionTile`，默认折叠）、**子项=该项目的归档会话**；
    父项行还有「恢复项目 / 删除项目」。
- 父项出现条件：项目自身已归档 **或** 其下有归档会话。
- 父项徽标（新增 `lib/models/archive_group.dart` 的 `ArchiveBadge`）：
  **全部** = 项目已归档且会话全归档；**部分** = 有归档会话但不满足「全部」；
  无归档会话/项目无会话 → 无徽标。分组与计数是**纯函数**（可单测）。
- **级联**（`AppState.setProjectArchived`）：归档项目 ⇒ 其下全部会话一并归档；
  恢复项目 ⇒ 其下全部会话（含此前单独归档的）一并恢复。
- **删除项目 ⇒ 连带删除其全部会话**（原语义是「脱离项目保留为独立会话」，已改）：
  `AppState.deleteProject` 逐个删 XML + 索引 + 内存态（缓存/控制器/审批队列），
  刷新四个列表。**工作目录不删**，重命名为 `_rec_<原名>`（同名再加 `_2`/`_3`…），
  失败只记日志不阻断删除。
- 删除确认：`confirmDeleteProject` —— **两次确认**：第一次明示「N 个会话会一并删除」，
  第二次「再次确认」。会话删除沿用原 `confirmDelete`（一次确认）。
  侧栏项目菜单的删除入口同步改用它。
- 版本：`0.6.11+1` → **`0.6.12+1`**（修订号 +1，构建号沿用仓库惯例保持 +1；
  `pubspec.yaml` 与 `lib/core/app_version.dart` 两处同步）。

**改了什么文件**

- 新增：`lib/models/archive_group.dart`（`ArchiveBadge` / `ArchiveProjectGroup` /
  `buildArchivedGlobalSessions` / `buildArchiveProjectGroups`）、
  `test/archive_group_test.dart`、`test/archive_page_test.dart`、
  `test/project_archive_cascade_test.dart`
- 改：`lib/state/app_state.dart`（读取器 `archivedGlobalSessions` /
  `archivedSessionsByProject` / `archivedCountOfProject` / `totalSessionsOfProject` /
  `archiveProjectGroups`；`setProjectArchived` 级联；`deleteProject` 连带删会话 +
  `_recycleSandbox` 回收工作目录）、
  `lib/ui/pages/archive_page.dart`（整页重写）、`lib/ui/widgets/confirm_dialog.dart`
  （新增 `confirmDeleteProject`）、`lib/ui/pages/home_page.dart`（侧栏删除入口）、
  `pubspec.yaml`、`lib/core/app_version.dart`、`FEATURES.md`、
  `.memory/ARCHITECTURE.md`（不变量 13/14）、`.memory/GOTCHAS.md`（§15）

**怎么验证**

- `flutter analyze lib test` → **No issues found**
- `flutter test` → **335 passed, 1 skipped**（基线 315 + 新增 20：分组/徽标纯逻辑 9、
  归档页 widget 6、级联与删除 5）
- 手工：建项目 + 3 会话 → 归档项目 → 归档·项目 Tab 父项显示「全部」、展开 3 个子项 →
  单独恢复 1 个 → 徽标变「部分」→ 恢复项目 → 3 个会话全回活动列表 →
  删除项目（两次确认）→ 项目与其会话消失、`<父目录>/_rec_<名>` 目录存在

**下一步 / 待验证**

- 用户侧真机确认归档页两个 Tab 的观感与徽标配色；`_rec_` 回收目录的清理策略
  （目前只增不减，需用户自行删除）。
- 提交/打标签/推送尚未执行（等用户确认后再做）。

**遗留问题**

- `_rec_*` 回收目录无自动清理；同名项目重复删除会产生 `_rec_x_2` 等多个副本。
- 工作目录跨文件系统或无写权限时重命名失败 → 目录原地保留（不删），仅记日志。
- 恢复项目会连带恢复此前**单独归档**的会话（按拍板执行）。
- 删除项目后其会话 XML 被真删，**不可恢复**（仅工作目录内容还在 `_rec_` 中）。

**拍板记录（勿擅自改回）**

1. 徽标「全部」= 项目自身已归档 **且** 会话全归档；「部分」= 其余有归档会话的情形。
2. 归档页只保留两个 Tab，项目本身的恢复/删除并入「归档·项目」的父项行。
3. 项目归档/恢复**级联**其会话；删除项目**连带删会话**并两次确认；工作目录不删，
   改名为 `_rec_<原名>` 回收。
4. Tab 文案用「归档·全局」/「归档·项目」；父项**默认折叠**。

---

## 2026-11-03 · 默认工具集改为空（空白会话默认不带 read_file）

**做了什么**

- 需求：定位「空白会话模板」用的工具代码后用户拍板 —— **默认工具集改为空**（方案 B，
  新旧路径统一）。
- `lib/models/app_config.dart`：
  - 构造器 `defaultTools = defaultTools ?? <String>[]`（原 `['read_file']`）；
  - `AppConfig.fromJson` 去掉 `isEmpty ? ['read_file']` 兜底，直接
    `defaultTools: asStringList(json['default_tools'])` ——**键缺失 = 空**。
- → 空白会话（`SessionWizardPage` 的「空白」chip → `_applyDefaults()` 取
  `config.defaultTools`）落盘 `<tools>` 为空，`AgentEngine` 的 `enabledTools` 为空，
  模型纯对话；会话信息对话框显示「（未启用）」。
- 老 `config.json` 若没有 `default_tools` 键，升级后也会变成「无工具」（这是本次
  有意接受的语义变更，不是 bug）。新建会话页**没有**工具勾选 UI，要给工具只能走
  模板或直接改会话 XML。

**改了什么文件**

- `lib/models/app_config.dart`（两处：构造器默认值、`fromJson`）

**怎么验证**

- 用户要求**只改不测**，本轮未跑 `flutter analyze` / `flutter test`。
  建议：`flutter analyze lib test`；`flutter test` 预计无红（`test/compress_test.dart`
  显式传了 `['read_file']`，无用例断言 `fromJson({}).defaultTools`）。
- 手工：删/改 `config.json` 的 `default_tools` → 新建「空白」会话 → 会话信息里
  「启动的工具」应为「（未启用）」。

**下一步**

- 若日后要给空白会话配工具，需要补一个 UI 入口（当前只有模板页 / 模板向导的
  FilterChip 列表，遍历 `BuiltinTools.descriptions.keys`）。

**补充（同日）：任务锚（每条 user 消息首行带任务标题）**

- 需求演进：先把标题塞进首条 user 消息（`promptText`），评估后改为**出站层注入**——
  标题的唯一出处仍是任务项，消息只存 `task_id`，发请求时按 id 反查。
- `lib/llm/outbound_adapter.dart` 的 `buildChatMessages`：
  - 先建 `taskTitles`（`task.anchorTitle`，即标题或内容首行；空任务没有锚）；
  - 每条 `user` 消息首行加 `【任务：<标题>】`：纯文本走 `ChatMessage.user`，
    多模态走 `userParts` 的第一个 `ContentPart.text`；工具图片合成的 user 消息取
    `pendingToolImages.first.taskId` 的锚；
  - 任务项已被删除 → 查不到 → **不加锚**；普通会话（无 tasks / 无 task_id）逐字不变。
- `TaskItem.promptText` 回退为**纯内容**（避免首条双标题）；新增 `TaskItem.anchorTitle`。
- 为什么这样最好（决策依据）：XML 零改动、界面/编辑框是用户原文、任务改名后历史消息
  自动用新标题，同时给方案 B 的扁平历史加了低成本分段标签（≈10 tokens/条）。

**遗留问题**

- 默认工具集无任何 UI 入口（只能改 `config.json` 或建会话后改 XML）。

---

## 2026-11-02 · 任务式会话（任务项分组 + 按任务显示）

**做了什么**（需求与拍板：4 条决策见本节末）

- 新增第三种「会话形态」：`Session.kind = SessionKind.task` + `Session.tasks[]`
  （`TaskItem{id,title,content,done}`）。普通会话文件格式**一字未变**（不写 `kind`/`tasks`），
  旧文件读出来就是 `normal`。
- 消息归属：`SessionMessage.taskId`。**同一次 turn 的 user/assistant/tool 消息同 taskId**，
  由 `AgentEngine(taskId:)` 统一打标；`system` 永不带。
- **上下文是方案 B**：出站历史仍是整个会话（`buildChatMessages(session)` 未改），
  `task_id` 只做显示过滤。这是本轮最容易踩反的地方（见 ARCHITECTURE 不变量 11/12）。
- 展示：`SessionChatPanel(taskId:)` 过滤消息 + 「返回任务列表」条（`TaskChatHeader`，
  带手动「完成」开关）+ `TaskListView`（标题 / 消息数 / 未开始 / 尚无回复 / 完成勾选 / 删除）。
  侧栏 tile 对任务式会话显示清单图标与 `已完成/总数`。
- 串行：一个会话仍只有一个 controller（`runningTaskId` 暴露给 UI）；有任务在跑时
  列表禁止切到别的任务/删除（提示先停止），流式区只在所属任务的视图里显示。
- 新任务（该项下**没有 assistant 消息**）进入对话时弹窗「开始这个任务？」：
  `立即发送` → 若还没有 user 消息则把 `## 任务标题` + 任务内容写成第一条 user 消息，然后
  `controller.resend(taskId:)` 跑一轮；`稍后（先看任务）` → 只看不发。
- 会话内可「新增任务 / 批量导入（`## 标题` 分段，`parseTaskMarkdown`）/ 勾选完成 / 删除」；
  删除**连同该项全部消息**并二次确认（`Session.removeTask`）。
- 创建：`SessionWizardPage` 增加「会话模式：普通 / 任务式」+ 任务项草稿编辑（逐项新增、
  批量导入、移除）；任务式至少一项才允许创建。**任务项小节的位置在工作目录（sandbox）
  之后**（`_TaskDraftSection`），会话模式的选项仍紧跟在「会话模式」标题下。
- 索引：`SessionIndexEntry` 增加 `kind` / `taskCount` / `taskDoneCount`，`CatalogIndex.version`
  3 → 4（缺 `kind` 的旧索引会重建；任务标题不进索引，打开会话时读 XML）。

**四条拍板决定（勿擅自改回）**

1. 上下文 = **方案 B**（整会话历史都发，任务项只是分组/显示维度）。
2. 新任务（无 assistant 消息）→ **弹窗问是否发送**，用户确认后任务内容作为首条 user 消息。
3. **串行**：不按任务拆 controller（同一 XML 不做并发写）。
4. 支持**新增/删除**（删除连带消息 + 二次确认）+ **手动标记完成** + **Markdown `##` 批量导入**。

**改了什么文件**

- 新增：`lib/models/task_item.dart`（`TaskItem` + `parseTaskMarkdown`）、
  `lib/ui/widgets/task_session_view.dart`（`TaskListView` / `TaskChatHeader` /
  `showTaskEditorDialog` / `showTaskImportDialog`）、`test/task_session_test.dart`、
  `test/task_session_flow_test.dart`
- 改：`lib/models/session.dart`（`SessionKind`、`tasks`、`taskById`/`taskMessages`/
  `taskHasReply`/`removeTask`、clone 带 kind+tasks）、`lib/models/session_message.dart`（`taskId`）、
  `lib/models/catalog_index.dart`（kind/计数 + version 4）、
  `lib/data/xml/session_xml.dart`（`kind` 属性、`<tasks>`、消息 `task_id`）、
  `lib/session/session_ops.dart`（`onlyTaskId` 限定 + 只删本任务的 tool 结果）、
  `lib/session/session_controller.dart`（`send/resend(taskId:)`、`runningTaskId`）、
  `lib/agent/agent_engine.dart`（`taskId` 打标）、`lib/state/app_state.dart`
  （`createSession/createSessionDraft(kind:, tasks:)`）、`lib/ui/pages/home_page.dart`
  （`_activeTaskId` + `_sessionArea` + 面板过滤/任务条/开始任务弹窗 + 移动端同样两段式 +
  侧栏 tile 徽标）、`lib/ui/pages/session_wizard_page.dart`（模式选择 + 任务项草稿）
- 文档：`FEATURES.md`（§1.2 XML 契约、§1.5 索引、§2 模型表、§7 功能表）、
  `.memory/ARCHITECTURE.md`（不变量 11/12）、`.memory/ANNOTATIONS.yaml`（`task_sessions`）

**怎么验证**

- `flutter analyze lib test` → **No issues found**（中途修掉一条 `prefer_interpolation_to_compose_strings`）
- `flutter test` → **315 passed, 1 skipped**（基线 287 + 新增 28：XML 往返 / 旧文件兼容 /
  索引计数 / 按任务删改不越界 / Markdown 解析 / TaskItem 回落与锚 / 出站锚 6 条 / 两条界面流程）
- `dart run tool/gen_memory_index.dart --check` → OK
- 建议手工路径：任务式会话建 2 项 → 打开列表 → 点第 1 项（弹窗）→ 立即发送 →
  回复只出现在第 1 项 → 返回列表看「1 条/未开始」计数 → 点第 2 项「稍后」→ 列表勾完成 →
  重启 App 确认 `kind/tasks/task_id/done` 都在。老会话打开应仍是普通对话（kind=normal）。

**下一步 / 待验证**

- 版本：`0.6.1+1` → **`0.6.11+1`**（修订号 +10，构建号沿用仓库惯例保持 +1；
  发版时两处同步改：`pubspec.yaml` 的 `version:` 与 `lib/core/app_version.dart`）。
- 用户侧只做真机体验确认：①「稍后」后再进入仍会再次询问（当前设计）；
  ②编辑重发/删除消息在任务视图里只影响本任务（`SessionOps(onlyTaskId:)`）；
  ③真实模型下逐项跑任务、切任务时的串行提示。

**遗留问题**

- 任务项**不能编辑标题/内容、不能排序**（拍板只要新增/删除）。
- 任务式会话的 `压缩会话` 仍按整会话生成（不按任务），产物是新会话、任务列表被 clone 但消息不带
  语义对齐 → 视为已知限制。
- 没有「按任务统计 token」；用量仍按整会话累计（`<system>` 属性）。
- 侧栏 tile 的 `已完成/总数` 徽标依赖会话对象里的 `tasks`：只从 index 建出来的
  `Session`（尚未打开过）`tasks` 为空，徽标要等首次打开（`reloadSession`）后才出现；
  索引里其实已有 `task_count/task_done_count`，但对齐它需要给 `Session` 加冗余计数，
  本轮没做。
- 任务式会话内**不能编辑任务的标题/内容**（拍板只要求新增/删除），要改只能编辑会话 XML。

---

## 当前快照

| 项 | 值 |
|---|---|
| 应用版本 | 0.7.0 (build 1) |
| 最近提交 | `dcc13fe` release: v0.6.11 — 任务式会话（已提交 + 打标签 + 推送 origin/main） |
| 工作区 | 干净（除两处与本轮无关的本地改动：`lib/models/app_config.dart` 的 defaultTools 默认值、未跟踪的 `.VSCodeCounter/`） |
| 记忆索引 | 已建立并在用：`.memory/`（7 个文件）+ `tool/gen_memory_index.dart`（MAP 已刷新） |

## 2026-10-30 · release: v0.6.1 — 输出上限按思考档位 / 模板显式指定

**做了什么**

两个功能点（细节见下面两节，不在此重复）：

1. **输出上限可按思考档位分别设置**（服务商配置）→
   见「输出上限（max_tokens）可按思考档位分别设置」
2. **会话模板显式指定「最大输出 tokens」** + 思考强度按钮 tooltip 显示生效上限 →
   见「会话模板显式「最大输出 tokens」+ 思考强度按钮 tooltip」

- 版本 0.6.0+1 → 0.6.1+1（构建号沿用仓库惯例保持 +1，见 `VERSIONING.md`）

**怎么验证**

- `flutter analyze lib test` → No issues found
- `flutter test` → 287 passed（新增 21 条）
- `dart run tool/gen_memory_index.dart --check` → OK

**下一步**

- 用户侧验证见下面两节的「下一步」。

---

## 2026-10-30 · 会话模板显式「最大输出 tokens」+ 思考强度按钮 tooltip

**做了什么**

- 会话模板（模板页直接编辑 + 模板向导）新增「最大输出 tokens」输入框：
  - **留空** = 不显式指定 → 用**模型服务商**的配置（可按思考档位分别设置，
    见上一节）；
  - **填了值** = 用这个显式值（盖过服务配置与档位表）。
- 落盘位置复用已有的 `SessionParams.maxTokens`（模板 XML 的
  `meta/params/max_tokens`，`template_xml` 的 `_paramsKeys` 本来就含它），
  新会话从模板创建时经 `createSessionDraft(params: template.params.copyWith())`
  继承；新建会话页同样继承（`(_template?.params ?? SessionParams()).copyWith()`）。
  → **存量模板/会话零迁移**。
- 优先级链（唯一出处）：**会话显式 max_tokens > 服务按档位算出的值 >
  服务固定值**；都没有 → 不限制（请求体不带输出上限参数）。
- 输入区下栏的「思考强度」按钮 tooltip 现在同时显示生效的输出上限：
  `思考强度：high · 最大输出tokens：3840`（不限制时显示「不限制」）。
  计算口径与请求体一致：会话显式值优先，否则
  `ProviderConfig.maxOutputTokensFor(会话 reasoning_effort)`。

**改了什么文件**

- `lib/ui/pages/templates_page.dart`（模板编辑：输入框 + 保存到
  `template.params.maxTokens`）
- `lib/ui/pages/template_wizard_page.dart`（向导同字段，落到新建模板的 params）
- `lib/ui/pages/home_page.dart`（`_ReasoningControls._maxTokensLabel` + tooltip 文案）
- `test/template_max_tokens_test.dart`（新增：模板→会话继承 / 留空=用服务配置 /
  显式值优先 / 编辑页输入并保存）
- `FEATURES.md`（§6 模板页行）、`.memory/ANNOTATIONS.yaml`（providers 契约）

**怎么验证**

- `flutter analyze lib test` → No issues found
- `flutter test` → **287 passed**（新增 4 条：模板→会话继承 / 留空=用服务配置 /
  显式值优先 / 编辑页输入并保存）
- 踩坑（已记入 `GOTCHAS.md §14`）：widget test 里「点保存 → 断言落盘」必须让
  **假时钟（`pump`）与真实事件循环（`runAsync`）交替**让行，
  只用 `pumpAndSettle` 会在保存完成前就断言 → 假失败。

**下一步**

- 用户侧验证：模板编辑 → 填「最大输出 tokens = 4096」→ 用该模板建会话 →
  输入区悬停思考强度按钮应显示「最大输出tokens：4096」；把模板里该字段清空 →
  显示服务配置算出的值（未配则「不限制」）。

**遗留问题**

- 会话运行中无法直接改输出上限（只有模板/会话参数里的 `max_tokens`），要改仍得
  改模板或 XML 编辑器。

---

## 2026-10-30 · 输出上限（max_tokens）可按思考档位分别设置

**做了什么**

- 模型服务页的「最大输出 tokens」输入框现在支持**两种写法**：
  - 固定值（`4096`）——与之前一致；
  - **按思考档位的规格串**：`{档位}:{长度}`，各档位用 `/` 分隔，
    如 `low:1280/medium:2560/high:3840/xhigh:5120`。
- 语义（与需求一致）：**当前思考档位命中 → 用该档位的长度；没有匹配的档位
  （含未选档位）→ 不限制**（请求体不带输出上限参数）。档位名不区分大小写。
- 数据流：
  `ProviderConfig.maxOutputTokensByEffort`（JSON `max_output_tokens_by_effort`）
  → `parseMaxTokensByEffort()` 解析成表 → `ProviderConfig.maxOutputTokensFor(effort)`
  → `llm_factory.buildOpenAiConfig(config, reasoningEffort: …)` 的
  `OpenAiCompatibleConfig.defaultMaxTokens` → 请求体 `max_tokens` /
  `max_completion_tokens`（参数名仍由 `useMaxCompletionTokens` 决定）。
- **会话级 `max_tokens` 仍然优先**（llm_api 里 `request.maxTokens ?? defaultMaxTokens`）；
  配了档位表就**取代**固定值（两者同时存在时以档位表为准）。
- 档位表只在**有思考档位**时生效：`AgentEngine` 建 provider 时把
  `session.params.reasoningEffort` 传进去；应用功能调用（自动命名、提示词润色）
  没有档位 → 不限制。
- 非法项被丢弃（`low:abc` / `bad` / `high:0`）；固定值 ≤0 仍按不限制处理。
  存量 `config.json` 不受影响（未设置时新键不落盘）。

**改了什么文件**

- `lib/models/provider_config.dart`（`maxOutputTokensByEffort` 字段 + JSON 往返 +
  `maxOutputTokensFor` + 顶层 `parseMaxTokensByEffort`）
- `lib/llm/llm_factory.dart`（`createProvider` / `buildOpenAiConfig` 增加
  `reasoningEffort` 参数，用 `maxOutputTokensFor` 解析上限）
- `lib/agent/agent_engine.dart`（建 provider 时传会话的思考档位）
- `lib/ui/pages/providers_page.dart`（输入框接受数值或规格串 + helper 文案 +
  保存时分类落到两个字段）
- `test/provider_max_output_test.dart`（新增 17 条：档位命中/未命中/未选档位/
  取代固定值/参数名/会话优先/解析容错/配置往返/编辑页保存）
- `FEATURES.md`（§2 ProviderConfig、§6 模型服务页）、`.memory/ANNOTATIONS.yaml`（providers 契约）

**怎么验证**

- 本轮 **shell 被托管模式拒绝**，`flutter analyze` / `flutter test` 未执行，
  需要用户侧跑一遍：
  ```sh
  flutter analyze lib test
  flutter test
  ```
- 预期：新增用例全绿，存量 268 条不变。

**下一步**

- 用户侧验证：模型服务页 → 「最大输出 tokens」填
  `low:1280/medium:2560/high:3840/xhigh:5120` → 会话里把思考强度切到
  `high` → 抓包/日志确认请求体带 `max_tokens: 3840`；切到 `minimal` → 该参数消失。
- 若要跑 `dart run tool/gen_memory_index.dart` 刷新 `.memory/MAP.yaml`
  （本次新增了 `parseMaxTokensByEffort` / `maxOutputTokensFor` 等符号，MAP 已过期）。

**遗留问题**

- 档位名按**字面**匹配：会话用 `max` 而表里写 `xhigh` 不会命中（= 不限制）。
  是否要做 `max`↔`xhigh` 别名映射，待定。
- 会话级 `max_tokens` 仍是**单一数值**，不能按档位；它一有值就压过档位表。
- 应用功能调用（自动命名 / 提示词润色）没有思考档位 → 配了档位表后它们不受限。

---

## 2026-10-30 · release: v0.6.0 — 项目记忆索引（.memory/）机制

**做了什么**

- 给「应用内创建的项目」加了记忆索引机制，结构与本仓库的 `.memory/` 同构：
  项目工作目录下维护 `.memory/`，含 `README.md` / `STATE.md` / `ARCHITECTURE.md` /
  `GOTCHAS.md` / `MAP.yaml` / `PROMPT.md` 六个文件。
- 骨架模板放在 `lib/core/memory_protocol.dart` 的 `memorySkeletonTemplates`，
  **语言无关**（应用内项目可能是任意语言，故没有生成器；事实层 `MAP.yaml`
  由 agent 用 glob/grep 自行维护）。
- 注入块 `memoryProtocolBlock` 自包含（约 200–400 tokens）：读哪些文件、
  收尾更新什么、三条红线（索引是路由不是内容 / 不写行号 / 事实只存一处）。
  `PROMPT.md` 骨架里引用同一份文本，协议正文只在 `.memory/README.md` §2/§4。
- 落盘位置：`<项目 sandbox>/.memory/`（随项目走，可提交到版本库，agent 的
  `read/write/glob/grep` 工具天然可达）。**不放在 App 数据根**——项目可指向
  外部文件夹，记忆必须跟着项目走。
- 开关与生命周期：
  - `Project.memoryEnabled`（项目 XML `<memory_enabled>`）是**三态**：
    `null` = 从未设置（老项目）→ 只有 `.memory/` 目录已存在才按「已启用」自愈，
    老项目行为不变；显式 `true`/`false` 遵从用户意图（**显式关掉的项目即使
    目录还在也不注入协议**——否则「关掉开关」会被自愈规则推翻）。
  - 建项目时自动生成骨架；`MemoryRepository.ensureSkeleton` **只补缺失文件**，
    绝不覆盖 agent 已写的内容。
  - 项目编辑对话框有「启用项目记忆（.memory/ 索引）」开关 + 状态行 +
    「初始化 / 补齐」按钮。
  - 新建会话页新增「④ 项目记忆协议」开关，默认跟随项目。
- **注入点唯一**：`AppState.createSessionDraft` 拼装系统提示词时追加
  （欢迎页「发送即建会话」、模板会话、向导页三条路径都经过它），并支持
  `useMemoryProtocol` 显式覆盖。
- 目录索引 `CatalogIndex.version` 升到 **3**：老 index.json 缺
  `memory_enabled`，不重建会静默关掉所有项目的记忆。
- **没有 `.memory/` 的项目如何补齐**（三条路径）：
  1. 单个：项目新建/编辑对话框的「初始化 / 补齐」按钮；或打开开关后确定
     （保存时自动补齐）。
  2. 全部：设置页「项目记忆索引」区 →「一键补齐全部项目」——遍历活动+归档
     项目，缺目录的补骨架并**显式启用**（`AppState.backfillProjectMemory`）。
  3. 自动：App 启动加载项目后 `AppState.healProjectMemory()`——对「已启用但
     目录被误删/从旧备份恢复」的项目重建骨架。
  三条路径都**只补缺失文件**，绝不覆盖 agent 已写的内容。

**改了什么文件**

- 新增 `lib/core/memory_protocol.dart`（协议块/marker/指针/骨架模板）、
  `lib/data/memory_repository.dart`、
  `lib/models/memory_status.dart`
- `lib/core/prompt_utils.dart`（`injectMemoryProtocol`：幂等 + 顶部指针）
- `lib/models/project.dart`、`lib/models/catalog_index.dart`、
  `lib/data/xml/project_xml.dart`（`memory_enabled`）
- `lib/state/app_state.dart`（`memoryRepository`、`createProject(memoryEnabled:)`、
  `ensureProjectMemory`、`projectMemoryStatus`、注入点）
- `lib/ui/pages/home_page.dart`（项目对话框的开关/状态行/初始化按钮）
- `lib/ui/pages/session_wizard_page.dart`（④ 记忆协议开关）
- `lib/ui/pages/settings_page.dart`（「项目记忆索引」运维区 + 一键批量补齐）
- `lib/ui/widgets/project_dialog.dart`（**新增**：项目对话框独立成 widget，
  自持控制器，修掉「used after being disposed」）
- 测试：`test/memory_protocol_test.dart`、`test/memory_repository_test.dart`、
  `test/project_memory_test.dart`、`test/project_memory_flow_test.dart`、
  `test/project_dialog_test.dart`（新增）；
  `test/session_wizard_prompt_test.dart`（向导多了一个开关，定位方式改为按标题找）
- 文档：`FEATURES.md`（§1.2/§1.3/§7/§9.1）、本文件、`.memory/ANNOTATIONS.yaml`

**怎么验证**

- `flutter analyze lib test` → No issues found
- `flutter test` → 268 passed（新增 47 条：模板内容 / 注入块 / 骨架非破坏 /
  XML 与索引往返 / 三态语义 / 显式关掉优先 / 目录已存在自愈 / 批量补齐 /
  启动自愈 / 会话级开关）
- `dart run tool/gen_memory_index.dart --check` → OK

**下一步**

- 用户侧验证：新建项目 → 确认工作目录出现 `.memory/`（6 个文件）→ 在该项目
  里新建会话 → 发一句话让 agent 读 `.memory/README.md` → 收尾后看
  `.memory/STATE.md` 是否被更新。

**协议说明强化（同日追加）**

- 问题：`.memory/` 的职责要不要在系统提示词里明确说明？——**要**，且已在说明。
  系统提示词是 agent 唯一可靠接收「行为规则」的通道；文件里的协议只有
  「agent 已经知道该读」时才有用（鸡生蛋）。
- 复查发现并修掉 3 个问题：
  1. **压缩会话重复注入**：`compressSession` 把已含协议块的 `source.systemPrompt`
     传回 `createSession` → 又追加一次，协议块出现两遍。修法：协议块以固定
     marker `【记忆索引 · .memory/】` 开头，注入前先查 marker → **幂等**
     （「一次注入 = 一个 marker」，指针行不许重复 marker）。
  2. **位置**：协议块原来只在末尾。改为「工作空间根目录」行之后插一行指针
     （先读 STATE.md，收尾更新 STATE.md），完整职责仍放末尾（长提示词下也
     看得见；收尾义务靠近对话，recency 效应）。
  3. **工具前提**：协议写明需 read_file/write_file（建议 glob/grep）；未启用时
     让 agent 直接提示用户去会话工具里开启，不要假装更新过索引。
- 顺手优化：开场只读 `STATE.md`，需要路由表/协议全文时再读 `README.md`
  （每个会话省一次工具调用）；骨架 README 的启动协议同步改成同一顺序。

**修复（同日追加）**

- 用户报：旧项目点「初始化 .memory」后报错
  `A TextEditingController was used after being disposed` + 两条框架断言。
- 根因：`_showProjectDialog` 在 `showDialog` 返回后**立刻** `dispose()` 了四个
  TextEditingController，而对话框的退出动画还在挂载着这些 TextField → 重建时
  访问已释放的 controller。
- 修法（标准写法）：把对话框抽成独立 widget
  `lib/ui/widgets/project_dialog.dart`（`ProjectDialog` + `ProjectDialogResult`），
  控制器由它自己持有、在自己的 `dispose()` 里释放——即路由真正移除后才释放。
  顺带把 `home_page.dart`（3000+ 行）里的一段挪走。
- 回归测试 `test/project_dialog_test.dart`：注入旧写法（pop 后立刻 dispose）
  会复现同一条报错，修好后通过。

**遗留问题**

- 记忆更新是**软约束**：agent 可能不写回 `.memory/`；二期可做「turn 结束检查
  STATE.md 是否被更新」的提醒。
- 补齐是**一次性**动作：项目被整体拷贝/迁移时 `.memory/` 跟着目录走；若有人
  只拷了源码没拷 `.memory/`，该目录会被当作「从未设置过」的项目（不注入）。
- 项目改名/换工作目录后 `.memory/` 不迁移（它属于目录，不属于项目记录）。
- `MAP.yaml` 没有生成器，靠 agent 手维护，准确性取决于 agent。

## 2026-10-29 · 提供商页「max_completion_tokens」改为可输入数值

**做了什么**

- 问题：模型服务页的「使用 max_completion_tokens」只是个开关，只能开/关；**全 App
  没有任何地方能填「输出多少 tokens」**——`SessionParams.maxTokens` 没有 UI 入口
  （设置页「默认参数」只有思考开关），所以请求体的输出上限一直是空的。
- 修法（拆成两个正交控件）：
  - 新增 `ProviderConfig.maxOutputTokens`（JSON 键 `max_output_tokens`）：
    **最大输出 tokens** 数值输入框，留空 = 不限制。
  - 原来的开关换成下拉「输出上限参数名」：`max_tokens`（通用）/
    `max_completion_tokens`（OpenAI o 系列 / gpt-5 只接受这个）；底层仍是
    `use_max_completion_tokens`，**存量 config.json 无需迁移**。
- 传递链路（保证真的传到 LLM）：
  `ProviderConfig.maxOutputTokens` → `llm_factory.buildOpenAiConfig` 的
  `OpenAiCompatibleConfig.defaultMaxTokens` → `OpenAiCompatibleProvider.buildRequestBody`
  的 `request.maxTokens ?? config.defaultMaxTokens` → 按参数名写入
  `max_tokens` / `max_completion_tokens`。
  **会话级 `max_tokens` 优先于服务级上限**。
- `llm_factory` 拆出 `buildOpenAiConfig(ProviderConfig)`，单测可直接检查请求体。

**改了什么文件**

- `lib/models/provider_config.dart`（`maxOutputTokens` 字段 + JSON 往返）
- `lib/llm/llm_factory.dart`（`buildOpenAiConfig` + `defaultMaxTokens`）
- `lib/ui/pages/providers_page.dart`（数值输入框 + 参数名下拉）
- `packages/llm_api/lib/src/providers/openai_compatible.dart`（`defaultMaxTokens`）
- `packages/llm_api/test/openai_compatible_test.dart`、`test/provider_max_output_test.dart`（新增用例）
- `FEATURES.md`（§2 ProviderConfig 字段、§6 模型服务页）、`.memory/ANNOTATIONS.yaml`（providers 契约）

**怎么验证**

- `flutter analyze lib test` → No issues found
- `flutter test` → 221 passed（新增 7 条：参数名两种、缺省不传、会话优先、JSON 往返、
  编辑页输入数值并保存）
- `cd packages/llm_api && dart test` → 66 passed
- `dart run tool/gen_memory_index.dart --check` → OK

**下一步**

- 用户侧验证：模型服务页填「最大输出 tokens = 4096」、参数名选 `max_completion_tokens`，
  发一条消息，确认请求体里有 `max_completion_tokens: 4096`。

**遗留问题**

- 会话级 `max_tokens` 仍无 UI 入口（只能靠模板 XML / `config.json` 的 `default_params`）；
  本次只补了服务级入口。要按会话覆盖，需在新建会话页/设置页补字段。

## 2026-10-29 · 新建会话页提示词三段式（会话 / 项目 / 新增）

**做了什么**

- 新建会话页（`lib/ui/pages/session_wizard_page.dart`）的系统提示词拆成三段：
  **① 会话提示词**（原字段，模板带入或手写）、**② 项目提示词**（开关「启用项目提示词」
  控制，来自所选项目）、**③ 新增提示词**（本次会话临时追加）。
- 拼装规则写死在 `lib/core/prompt_utils.dart` 的 `composePromptSections`：
  顺序固定，**空段丢弃**，段间用 `\n---\n` 分隔；`工作空间根目录` 行仍由
  `injectWorkspaceRoot` 写在最上面。
- 项目提示词落在项目上：`Project.systemPrompt` → 项目 XML 的 `<system_prompt>`（CDATA）→
  `ProjectIndexEntry.system_prompt`（index.json 版本 1 → **2**，旧索引自动重建，
  否则老索引会静默丢掉所有项目提示词）。
- 编辑入口放在**项目编辑面板**：`home_page.dart` 的新建/编辑项目对话框新增「项目提示词」
  多行输入框（对话框加了滚动 + 固定宽度，避免小屏溢出）。
- 选了带提示词的项目时开关默认打开（可再关掉）；项目无提示词时开关置灰不可用。

**改了什么文件**

- `lib/core/prompt_utils.dart`（`kPromptSectionSeparator` + `composePromptSections`）
- `lib/models/project.dart`、`lib/models/catalog_index.dart`（`systemPrompt` 字段 + JSON）
- `lib/data/xml/project_xml.dart`（`<system_prompt>` 编解码）
- `lib/state/app_state.dart`（`createProject(systemPrompt:)`）
- `lib/ui/pages/home_page.dart`（项目编辑面板 + 提示词字段）
- `lib/ui/pages/session_wizard_page.dart`（三段式 UI + 拼装）
- `test/project_prompt_test.dart`、`test/session_wizard_prompt_test.dart`（新增）
- `FEATURES.md`（§1.3 项目字段、§7 会话功能两行）

**怎么验证**

- `flutter analyze lib test` → No issues found
- `flutter test` → 214 passed（新增 10 条用例：拼装顺序 / 空段 / XML 往返 / 索引往返 /
  向导页开关默认态与关闭态）
- `dart run tool/gen_memory_index.dart --check` → OK

**下一步**

- 用户侧验证：真机建项目 → 写项目提示词 → 项目内新建会话，确认开关默认打开、
  落盘的 `<system>` 内容里三段以 `---` 分隔。

**遗留问题**

- 欢迎页「发送即建会话」的路径（`home_page.dart` 的 `_startSession`）走
  `createFromTemplateDraft`，**不经过新建会话页**，因此不会并入项目提示词；
  若希望该路径也带上项目提示词，需要在 `AppState` 层再补一次拼装。

---

## 2026-10-28 · 收敛提示词层（AGENTS.md 指针 + 协议单一出处）

**做了什么**

- 新增仓库根 `AGENTS.md`（1 行），让支持该约定的 harness 自动把索引协议带进系统提示词。
- 发现原来的 `PROMPT.md` 完整版与本文件 §2/§4 重复，改协议要改两处 → 会漂移。
  现改为：`AGENTS.md`（指针）→ `.memory/README.md` §2/§4（**协议权威出处**），
  `PROMPT.md` 只留注入块与场景说明。
- `README.md` §2 补上【红线】（索引是路由不是内容 / 不写行号 / 不擅自改设计结论）。

**改了什么文件**

- `AGENTS.md`（新增，1 行）
- `.memory/PROMPT.md`（瘦身：完整协议副本 → 注入块 + 场景说明）
- `.memory/README.md`（§2 标注权威出处 + 补红线）

**怎么验证**

- 注入块与 `AGENTS.md` 原文逐字一致（`diff` 复核）
- `dart run tool/gen_memory_index.dart --check` → OK

**下一步**

- XChat 应用内使用时：确认会话工作目录能解析到仓库，否则注入块要写绝对路径。

## 2026-10-28 · 删除 AGENTS.md，提示词改走 XChat 原生机制

**做了什么**

- 复核后发现：本项目唯一的 agent 就是 XChat 自己，`lib/` 84 个文件里**没有任何读取
  `AGENTS.md` 的代码** —— 那行文件对主场景零功能价值。
- 更关键的是认知危害：曾把「仓库级自动注入（已启用）」当作生效方案写进 `PROMPT.md`，
  而那条路径根本不工作。已删除 `AGENTS.md`，并在 `PROMPT.md` 写清删除理由与恢复方式。
- 注入块改为**不依赖 AGENTS.md 约定**：利用 XChat 既有机制 —— `injectWorkspaceRoot`
  会把 `工作空间根目录: <绝对路径>` 写在系统提示词首行，注入块据此把 `.memory/`
  解析为相对仓库根的路径。
- XChat 的原生自动入口是**会话模板的系统提示词**（`system_prompt`，随模板存盘），
  从模板建会话即自动带上，已写进 `PROMPT.md` 场景表。

**改了什么文件**

- 删除 `AGENTS.md`
- `.memory/PROMPT.md`（重写：注入块 + 场景表 + 删除理由）
- `.memory/README.md`（§2 注释改为指向 `PROMPT.md`）

**怎么验证**

- `grep -rn "AGENTS" .memory/` → 仅剩「按需临时创建」的说明
- `dart run tool/gen_memory_index.dart --check` → OK

**下一步**

- 想在 XChat 里自动生效：新建一个会话模板，系统提示词填注入块，工作目录指向仓库根。

## 2026-10-29 · 修复「代码围栏之后文本选不中」（方案 A）

**做了什么**

- 定位并修复回归：v0.5.6 的「修复复制丢换行」补丁会让**代码围栏之后的所有段落
  无法被选中复制**（用户报「靠后的文本选不中」）。
- 根因（详见 `GOTCHAS.md` §8.1）：`_selectableBlock` 给每个文本块追加的隐藏
  `SizedBox(height: 0, child: Text('\n'))`，经 `_SafeCodeBlockNode` 里的
  `ProxyRichText` 进入了代码围栏的 `WidgetSpan` 子树。`Text('\n')` 宽高都是 0，
  包围盒退化，破坏了 `SelectionArea` 串联选区时的屏幕顺序比较，选区扩展到围栏处即中断。
  实测：列表 / 引用 / 标题 / 表格 / 公式 / 分隔线都不触发，**只有代码围栏触发**。
- 修法（方案 A）：围栏内部不再走 `richTextBuilder`，直接拼 `Text.rich`。
  围栏与后续段落之间的换行由该块在顶层拿到的 break 提供。

**改了什么文件**

- `lib/ui/widgets/markdown_view.dart`（`_SafeCodeBlockNode.build()` 内部渲染）
- `test/markdown_copy_test.dart`（新增回归用例
  "text after a code fence stays selectable"）
- `.memory/GOTCHAS.md`（§8.1 补修法与推论）、`.memory/STATE.md`（本节）

**怎么验证**

- A/B（真实 `markdownView`，拖选整段后读剪贴板）：

| 文档 | 修复前 | 修复后 |
|---|---|---|
| 围栏在中间 | `alpha one\nvar a = 1;\nvar b = 2;`（尾部丢失） | `alpha one\nvar a = 1;\nvar b = 2;\nomega two\n` |
| 围栏在最前 | `var a = 1;`（尾部丢失） | `var a = 1;\nomega two\n` |
| 围栏在最后 | `alpha one\nvar a = 1;\nvar b = 2;` | `alpha one\nvar a = 1;\nvar b = 2;\n` |
| 普通段落 / 列表 / 表格 | 不变 | 不变 |

- `flutter analyze lib test` → No issues found
- `flutter test` → 202 passed

**下一步**

- 用户侧验证：真实 App 里拖选一段含代码围栏的消息，确认围栏前后都能选中、
  粘贴换行正常。
- 未做的更大项（方案 D，需另行拍板）：让围栏 / 表格 / 列表不再渲染成
  `WidgetSpan`，以实现**跨块完全连续选中**（当前跨 `WidgetSpan` 是 Flutter
  框架级限制）。

**遗留问题**

- `math_support.dart` 的公式也是 `WidgetSpan`：行内公式所在段落之后的内容仍可选，
  但公式本身与前后文之间的**连续选择**做不到（框架限制，未处理）。

## 2026-10-28 · 建立记忆索引

**做了什么**

- 建 `.memory/` 索引：`README.md`（入口路由）、`ARCHITECTURE.md`（分层与不变量）、
  `GOTCHAS.md`（雷区）、`STATE.md`（本文件）、`MAP.yaml`（机读事实）、
  `ANNOTATIONS.yaml`（职责/风险/功能→文件映射）。
- 写 `tool/gen_memory_index.dart`：扫描 `lib/` 与 `packages/llm_api/lib/`，
  产出模块→文件→顶层符号、模块依赖图、测试清单；支持 `--check` 检测过期。
- 事实层全部由扫描得出（相对 import 解析 + 最长前缀模块归属），不手抄。

**改了什么文件**

- 新增 `tool/gen_memory_index.dart`
- 新增 `.memory/*`（7 个文件）
- 新增仓库根 `AGENTS.md`（一行，指向 `.memory/README.md`，供 harness 自动注入）—— 同日已删除，见下节
- 未改动任何 `lib/` 代码

**怎么验证**

```sh
dart run tool/gen_memory_index.dart --check   # 期望：OK .memory/MAP.yaml 与代码一致
flutter test                                   # 回归（本次未动 lib/，应全绿）
```

**下一步**

- 待补：把 `features[].files` 与真实改动对齐（目前是首版推断，需在实际改代码时校正）。
- 待补：`GOTCHAS.md` 里 Android 共享存储目录、`DESIGN.md §19` 的脚本合并优先级尚未逐行核对。

**遗留问题**

- `home_page.dart` 2940 行，尚未拆分；索引只能标出它大，没法细分内部结构。
- `pkg.llm_api` 是 vendor 代码，索引把它当普通模块处理，但它有自己的 pubspec 与测试。

---

## 模板（复制到新一节）

```markdown
## YYYY-MM-DD · 本次标题

**做了什么**

**改了什么文件**

**怎么验证**

**下一步**

**遗留问题**
```
