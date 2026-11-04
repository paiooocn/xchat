# 实施规划：带 AI 助手的 Markdown 笔记

> 面向**新会话**：照着本文逐条实施即可，不需要重新做设计。
> 设计稿：`docs/NOTES_AI_DESIGN.md`（功能设计）· `docs/mockups/notes_ui.html`（UI 设计图）
> 本文件是**实施层的唯一真相**：文件清单、步骤、契约、验收口径都在这里。
> 状态：**待实施**（本次会话只出规划，未写任何实现代码）

---

## 0. 一句话目标

在 XChat 的左栏加一个「笔记」Tab：笔记是 `<root>/notes/<id>.md`（Markdown + front-matter），
主区是**上预览 / 下编辑**的上下分屏，右侧是**可展开可收起**的 AI 助手边栏；
AI 的任何改写都必须先过 diff 预览再写回。

---

## 1. 已拍板的决策（**勿擅自改回**）

| # | 决策 | 说明 |
| --- | --- | --- |
| D1 | **笔记不新增路由** | 是 `HomePage` 左栏的一个 Tab，与「会话」并列；主区按 Tab 切换 |
| D2 | **中间栏只有一套布局** | 取消「编辑 / 分屏 / 预览」三选一模式切换；固定上预览 / 下编辑 |
| D3 | **下区高度三档** | `40%` / `20%` / `0%（收起）`；分隔条可拖动，**吸附到最近档位** |
| D4 | **AI 边栏两态** | 展开 320px / 收起 44px 竖轨（保留 AI 图标 + 「生成中」角标） |
| D5 | **AI 写回必过 diff** | 任何 AI 改正文都先弹 diff → 接受/拒绝；接受后进编辑器缓冲（可 Ctrl+Z） |
| D6 | **存储用 Markdown 文件** | `<root>/notes/<id>.md` + front-matter，不是会话那套 XML |
| D7 | **移除「新建会话」行** | 侧栏不再有那一行；改为顶行图标按钮，紧挨「刷新会话列表」右侧 |
| D8 | **刷新按钮复用** | 同一个 widget 复用，按 Tab 换 tooltip 与行为（会话列表 / 笔记列表） |
| D9 | **移动端不保留双入口** | 底部 Tab `会话｜笔记` 是唯一工作区切换；不同时再提供抽屉入口 |
| D10 | **AI 用应用功能调用模型** | 默认取 `AppState.appFeatureTarget`；笔记页可临时切换 |
| D11 | **快捷键不白捡** | `Ctrl+N` 现状只是文案标签、无真实绑定；删「新建会话」行后若要真快捷键，需新写绑定（属新增能力，单列任务） |

### 本轮补充的实现约定（未单独拍板，按最小改动取值）

- **下区高度档位**持久化在 `SharedPreferences`（全局默认 `notes_editor_split_ratio`），
  **不做**按笔记的 per-note 覆盖，也不写进 front-matter —— 避免 front-matter 膨胀与
  跨设备语义混乱。若以后要 per-note，再加一个可选 front-matter key 即可
  （读时缺省回落到全局值，天然向后兼容）。
- **AI 上下文裁剪阈值**写进 `config.json`：`notes_context_char_limit`，默认 `12000`。
- **笔记内嵌图片附件**：一期**不做**，只支持纯 Markdown + 外部相对路径引用。
- **AI 边栏在生成中不允许收起**（收起按钮置灰）；正在跑的请求不中断。

---

## 2. 现状锚点（真实代码位置，实施时按这些名字找）

| 主题 | 位置 |
| --- | --- |
| 侧栏外壳 | `lib/ui/pages/home_page.dart` → `_Sidebar`（类）、`_brandRow`、`_navList`、`_navEntries`、`_bottomRow` |
| 侧栏调用点 | `lib/ui/pages/home_page.dart` → `_HomePageState.build`（宽屏 `Row` / 窄屏直接 `_Sidebar`） |
| 侧栏入口路由 | `lib/ui/pages/home_page.dart` → `_navigate`（`'new' / 'search' / 'templates' / …`） |
| 主区 | `lib/ui/pages/home_page.dart` → `_sessionArea`；欢迎页 `_WelcomeView` |
| 移动端会话页 | `lib/ui/pages/home_page.dart` → `_MobileChatPage` |
| Markdown 渲染（**直接复用，勿重写**） | `lib/ui/widgets/markdown_view.dart` → `markdownView(data, {codeBackground})` |
| 公式 | `lib/ui/widgets/math_support.dart` → `mathInlineSyntaxes` / `mathSpanGenerators` |
| 应用级 LLM 调用范式 | `lib/llm/prompt_assistant.dart` → `_stream()` + `_unwrap()` + `llm.CancelToken` |
| provider 工厂 | `lib/llm/llm_factory.dart` → `createProvider` / `buildOpenAiConfig` |
| 应用功能调用模型 | `lib/state/app_state.dart` → `appFeatureTarget` |
| 全局状态 | `lib/state/app_state.dart` → `AppState`（`ChangeNotifier`，全局唯一） |
| 数据根目录 | `lib/core/app_paths.dart` → `AppPaths`（`root` / `sessionsDir` / `projectsDir` / `ensureDirs()`） |
| 索引 | `lib/models/catalog_index.dart` → `CatalogIndex`（`version` 现为 **4**）、`lib/data/index_repository.dart` → `IndexRepository` |
| 原子写盘范式 | `lib/data/session_repository.dart` → `_writeAtomic`（tmp + rename，含 Windows 回落） |
| 模板仓库（目录扫描范式） | `lib/data/template_repository.dart` → `TemplateRepository` |
| ID 生成 | `lib/core/ids.dart` → `newId()` |
| JSON 容错读 | `lib/core/json_utils.dart` → `asMap/asString/asInt/asBool/asStringList` |
| 确认弹窗 | `lib/ui/widgets/confirm_dialog.dart` → `confirmDelete` |
| 外部编辑器 | `lib/util/editor_launcher.dart` → `openInEditor` / `openDirectory` |
| 主题令牌 | `lib/ui/theme/app_theme.dart` → `AppTheme.radiusSmall/Medium/Large`、`sidebarWidth=288` |
| 字体 | `lib/ui/theme/app_fonts.dart` → `AppFonts.sans` / `AppFonts.mono` |
| 现有测试目录 | `test/`（命名 `<主题>_test.dart`） |

### 必须遵守的跨层不变量（`.memory/ARCHITECTURE.md` §5）

1. **序列化只在 data 层**：`models` 里不得出现文件拼装逻辑 → front-matter 的拼装/拆解放 `lib/data/xml/note_md.dart`。
2. **UI 不直接碰文件系统**：一律经 repository。
3. **全局状态只有一个** `AppState`；笔记列表挂这里，不要另造 store。
4. **新字段必须能读旧文件**：front-matter 缺 key 走默认；未知 key 原样保留。
5. **`index.json` 是缓存，磁盘是事实**：加载时校验，不一致透明重建。
6. 改 `CatalogIndex.version` 时**必须递增**（老索引会被丢弃重建，这是既定机制，不要试图兼容老版本）。

### 必须规避的已知坑（`.memory/GOTCHAS.md` §8）

- 预览**必须**走 `markdownView()`，否则代码高亮 / 公式 / 表格列宽 / 复制换行这些已修过的坑全部复现。
- `TableConfig(defaultColumnWidth: FlexColumnWidth())` 已在 `markdown_view.dart` 内 —— 表格里带公式才不会崩。
- `SelectionArea` 的选区按屏幕顺序串联：**不要**把隐藏文本类小控件放进 `WidgetSpan` 子树。

---

## 3. 目标结构

```
┌ 左栏（288px，两态共用外壳）────────────────────────────┐
│ 顶行  [X] XChat        [↻刷新][＋新建][⌂回到首页]      │
│ Tab   [ 会话 | 笔记 ]                                  │
│ 列表区  会话 Tab → 项目 + 全局会话树                   │
│         笔记 Tab → 搜索 + 置顶/最近/标签/归档           │
│ 底行  品牌 + 审批/模板/更多/主题                        │
└────────────────────────────────────────────────────────┘
        主区
   会话 Tab → 现有聊天区（消息流 + 输入区）
   笔记 Tab → AppBar(标题 / 40%|20%|收起 / 收起AI / ⋮)
               ├ 上区：预览（markdownView）
               ├ 分隔条（可拖，吸附档位）
               ├ 下区：编辑（源码，等宽）
               └ 状态条（已保存 / 字数 / 标签）
             + AI 边栏 320px（收起 44px 竖轨）
```

---

## 4. 实施阶段

> **每个阶段结束都要跑**：`flutter analyze lib test`（必须 No issues found）与 `flutter test`（必须全绿）。
> 阶段之间可以独立提交；不要一次性铺开所有阶段。

### M0 · 地基层：模型 / 存储 / 索引

**目标**：能在磁盘上存取笔记，索引能列出笔记摘要。**不碰 UI。**

**新增文件**

| 文件 | 职责 |
| --- | --- |
| `lib/models/note.dart` | `Note`（完整笔记：元数据 + 正文）、`NoteSummary`（列表摘要，无正文） |
| `lib/data/xml/note_md.dart` | front-matter 与正文的**拼装/拆解**（序列化只在这层） |
| `lib/data/note_repository.dart` | 读写 `<root>/notes/<id>.md`、原子保存、扫描目录、CRUD |

**修改文件**

| 文件 | 改动 |
| --- | --- |
| `lib/core/app_paths.dart` | 加 `String get notesDir => p.join(root, 'notes');` + `String noteFile(String id) => p.join(notesDir, '$id.md');`；`ensureDirs()` 的目录列表加 `notesDir` |
| `lib/models/catalog_index.dart` | 加 `List<NoteIndexEntry> notes`；`CatalogIndex.version` **4 → 5**；`toJson`/`fromJson` 加 `'notes'` 桶 |
| `lib/data/index_repository.dart` | `rebuild()` 扫 `notes/` 解析 front-matter 写进 `notes` 桶；`_matchesDisk()` 增加 `notes/` 目录 id 集合比对；加 `upsertNote` / `removeNote` |
| `lib/state/app_state.dart` | 加 `List<Note> notes` / `archivedNotes`；`refreshNotes()` / `refreshArchivedNotes()`；CRUD 转发给 repository；`load()` 里调用刷新 |

**数据契约**

front-matter（只认白名单 key，**未知 key 原样保留**）：

```markdown
---
id: 9f2c1e0a-...        # 必填，= 文件名
title: 会议纪要 · 2026-11-04   # 必填；空则取正文首个 "# " 标题
tags: [会议, 项目A]      # 可选
created_at: 2026-11-04T09:12:33Z   # 必填，UTC ISO8601
updated_at: 2026-11-04T10:02:11Z   # 必填，UTC ISO8601
pinned: false           # 可选，默认 false
archived_at: null       # 可选；非空则进归档桶
---

# 正文从这里开始
```

- 正文与 front-matter 之间**一个空行**；正文原样保留（含空行、缩进、代码围栏）。
- 解析：文件头不是 `---` 视为「裸 Markdown」，可导入为笔记（补齐头部），不报错。
- 写回时**只重写 front-matter 块**，正文按用户原文逐字写回（禁止格式化）。

索引条目（`NoteIndexEntry`，进 `index.json` 的 `notes` 桶）：

```json
{ "id": "...", "title": "...", "tags": ["会议"], "created_at": "...",
  "updated_at": "...", "pinned": false, "archived_at": null, "preview": "正文前 80 字" }
```

**关键实现点**

- 原子写：照抄 `SessionRepository._writeAtomic` 的 tmp+rename+Windows 回落写法。
- 列表扫描：只读每个 `.md` 的**前 4KB** 解析 front-matter + 取正文前 80 字做 preview；
  完整正文**只在打开该笔记时读**（照 `SessionRepository` 的「列表带元数据、正文懒加载」思路）。
- 索引只放摘要，**不放正文**。

**测试**（新建 `test/note_storage_test.dart`）

- front-matter 往返：写 → 读，字段全等；正文逐字相等（含空行与缩进）
- 未知 key 保留；缺 key 走默认；裸 Markdown 可导入
- 索引往返（`CatalogIndex.version` 5）；旧版本索引（version 4）被丢弃重建
- 原子写：`.tmp` 不残留
- 摘要扫描只读前 4KB（写一个超长文件，断言列表不慢、不截断 preview）

**验收**：能新建/保存/读取/删除/归档一篇笔记；`index.json` 里出现 `notes` 桶；索引损坏能重建。

---

### M1 · 侧栏 Tab + 顶行按钮（**纯 UI，可独立先做**）

**目标**：左栏出现「会话 | 笔记」Tab；「新建会话」行移除、改为顶行图标按钮。
（笔记 Tab 的列表内容此时可以先放占位空态。）

**修改文件**：`lib/ui/pages/home_page.dart`

1. 新增枚举（在 `home_page.dart` 顶部私有）：
   ```dart
   enum _WorkspaceTab { session, note }
   ```
2. `_HomePageState` 加字段 `WorkspaceTab _tab = _WorkspaceTab.session;`
3. `_Sidebar` 加参数：
   - `required _WorkspaceTab tab`
   - `required ValueChanged<_WorkspaceTab> onTabChanged`
   - `required Widget Function() onNewNote`（笔记 Tab 的新建）
   - `required List<Note> notes`（M0 之后接上；M1 阶段可先传空列表占位）
4. `_Sidebar.build`：`_brandRow` 之后插入 Tab 行（**顶行下方、列表上方**）
   - 样式：分段控件（`surfaceContainer` 底 + 圆角 12），选中项白底 + 主色图标
   - Tab 切换时：**列表区内容与主区同步换**（`_Sidebar` 内部按 `tab` 决定渲染会话树还是笔记列表）
5. `_brandRow` 改造（D7/D8）：
   - 右侧依次：`↻ 刷新` → `＋ 新建`（**primary 实心**图标按钮）→ `⌂ 回到首页`
   - 「＋ 新建」在会话 Tab = 新建会话（走 `_newSession`），在笔记 Tab = 新建笔记
   - **同一个 widget 复用**（D8）：刷新按钮只改 tooltip 与回调
     （会话 Tab：`刷新会话列表` → `_refreshSessions`；笔记 Tab：`刷新笔记列表` → `refreshNotes`）
   - 刷新中的 spinner 逻辑沿用现有 `refreshingSessions`
6. **删除** `_navEntries`（那个只有「新建会话」一项的列表）、`_navList` 方法、`_NavRow` 类
   —— 全仓检索确认 `_NavRow` 只被 `_navList` 使用（`home_page.dart` 内 `_NavRow` 与
   `onNavigate?.call(entry.id)` 是它的唯一使用点），可整块删
7. **连带清理**：`_navigate` 的 `case 'new':` 分支会变成死代码 ——
   `'new'` 这个 id 只由 `_navEntries` 产生（`_navigate` 的其他调用点是「更多」菜单，
   其 value 只有 theme / tools / pip / providers / archive / settings）。
   删 `_navEntries` 时一并删掉 `case 'new'`，否则 `analyze` 不会报错但会留下不可达分支
8. **快捷键**：现状 `Ctrl+N` **只是 `_navEntries` 里的文案标签（`shortcut: 'Ctrl+N'`），
   全仓没有任何真正的按键绑定**（`Shortcuts` 只出现在 `lib/ui/widgets/input_area.dart`，
   管的是 Enter / Ctrl+Enter 换行）。
   → 删掉那一行后快捷键提示会一起消失。若要保留「Ctrl+N 新建会话」这个**真**快捷键，
   需**新写**绑定（放在 `HomePage` 的 `Shortcuts`/`CallbackAction` 里，或 `Shortcuts`
   + `Actions`），并另加 `Ctrl+Shift+N` 新建笔记；这是**新增能力**，不是「保留现状」，
   建议单列一条任务，别混在 M1 里

**不要动**：`_navigate` 里 `'new'` 分支（工具条/更多菜单也可能用）—— 确认无引用再删。

**测试**（新建 `test/sidebar_tab_test.dart`）

- 渲染 `HomePage`：断言存在「会话」「笔记」两个 Tab
- 点「笔记」Tab → 断言主区切到笔记视图占位、左栏出现笔记列表占位
- 断言侧栏**不再有**「新建会话」文字行
- 断言顶行存在刷新图标按钮与新建图标按钮，且新建按钮在刷新按钮**右侧**
  （按 `test/widgets` 里 `find.byTooltip` / `tester.getCenter` 比对 x 坐标）

**验收**：侧栏外观与 `docs/mockups/notes_ui.html` 画板①一致。

---

### M2 · 笔记编辑区（上预览 / 下编辑）

**目标**：笔记主区可用：预览渲染、源码编辑、自动保存、下区高度三档。

**新增文件**

| 文件 | 职责 |
| --- | --- |
| `lib/ui/pages/notes_panel.dart` | 笔记主区面板（AppBar + 上下分屏 + AI 边栏占位） |
| `lib/ui/widgets/note_editor.dart` | 上预览 / 下编辑 + 分隔条 + 高度档位 + 工具栏 |
| `lib/ui/widgets/note_list.dart` | 左栏笔记列表（搜索 / 置顶 / 最近 / 标签 / 归档 / 行菜单） |

**修改文件**

- `lib/ui/pages/home_page.dart`：笔记 Tab 的主区 → `NotesPanel`；左栏笔记列表 → `NoteList`
- `lib/models/app_config.dart`：加 `notesContextCharLimit`（JSON `notes_context_char_limit`，默认 12000）——
  供 M3 用，M2 可先不加

**编辑区规格**

```
上区：预览   flex，flex:1，始终渲染 markdownView(正文)
分隔条：可拖动，拖动结束吸附到最近档位（40% / 20% / 0%）
下区：编辑   高度 = 档位（0% 时隐藏编辑区与分隔条，预览占满）
状态条：已保存 / 保存中… / 未保存 · 字数 · 标签 · 「用编辑工具打开」
```

- **预览**：直接 `markdownView(text)`；改动后 **300ms 防抖**重渲
- **编辑**：`TextField`（`maxLines: null`, `expands: true`）+ 等宽字体 `AppFonts.mono`；
  可选行号
- **工具栏**（语法包裹，不是所见即所得）：粗体 / 斜体 / H1-H3 / 无序列表 / 任务列表 /
  有序列表 / 代码块 / 行内码 / 链接 / 表格 / 引用 / 公式 / 图片 / 用编辑工具打开
  - 选中文字 → 包成 `**…**` / `*…*` / `` `…` `` / `> …`
  - 无选区 → 插入模板片段（表格骨架、任务列表行、`- [ ] ` 等）
- **自动保存**：停写 **800ms** 后落盘（`NoteRepository.write`），状态条实时反映
- **手动保存**：`Ctrl+S`
- **档位持久化**：`SharedPreferences` 键 `notes_editor_split_ratio`，值 `40|20|0`
- **外部改动检测**：编辑期间记录打开时 `mtime`；保存前若 `mtime` 变了 → 弹窗
  「磁盘上的笔记已变更」→ 用户选「重新加载（丢弃本地）」/「保留本地（覆盖）」

**测试**（新建 `test/note_editor_test.dart`）

- 渲染 `NotesPanel`：断言预览区出现 `markdownView` 的产物（标题文本可见）
- 改源码 → 推进 800ms + 假时钟 → 断言文件内容更新
- 档位切换 → 断言 `SharedPreferences` 里写入 `40/20/0`
- 0% 档 → 断言编辑区不可见（`find.byType(TextField)` 找不到）
- 工具栏「粗体」在有选区时把 `**` 包上

> ⚠️ widget test 里的定时器：保存是异步 IO，**必须让假时钟（`pump`）与真实事件循环
> （`runAsync`）交替**推进，否则断言会在落盘前执行 → 假失败。
> 参考 `.memory/GOTCHAS.md` §14 的同款提醒。

**验收**：编辑 → 预览同步 → 自动保存 → 重启仍在；预览里的公式/代码/表格与聊天消息观感一致。

---

### M3 · AI 助手（改写 / 生成 / 问答 + diff 写回）

**目标**：右侧 AI 边栏可用，AI 结果经 diff 确认后写回。

**新增文件**

| 文件 | 职责 |
| --- | --- |
| `lib/llm/note_assistant.dart` | 构造 prompt、流式执行、结果后处理 |
| `lib/ui/widgets/note_ai_panel.dart` | AI 边栏（两态：展开 320 / 收起 44 竖轨） |
| `lib/ui/widgets/note_diff_dialog.dart` | diff 预览弹层（接受 / 拒绝） |
| `lib/util/line_diff.dart` | 纯 Dart 行级 LCS diff（**不引新依赖**） |

**修改文件**

- `lib/ui/pages/notes_panel.dart`：挂 AI 边栏
- `lib/ui/widgets/note_editor.dart`：暴露「当前选区」「插入光标处」「替换选区」的入口
- `lib/models/app_config.dart`：`notesContextCharLimit`（若 M2 未加）

**AI 能力清单**

| 组 | 动作 | 产物去向 |
| --- | --- | --- |
| 改写 | 润色 / 扩写 / 缩写 / 改写语气 / 翻译 / 纠错 / 转换格式 | **diff 预览** |
| 生成 | 续写 / 摘要 / 标题 / 标签 / 大纲 / 会议纪要模板 / 复习卡片 | 插入光标处 / 追加文末 / 复制 |
| 问答 | 基于笔记提问 | 只读，不写文档（可手动「作为附录插入」） |

**上下文构造**（system + user）：

```
system:
  你是 Markdown 笔记助手。当前笔记标题是「{title}」。
  规则：
  - 输出必须是 Markdown 片段，不要用 ``` 包裹整篇，不要写解释性前言。
  - 除非明确要求「重写全文」，否则只输出被修改/新增的那部分。
  - 保留原有标题层级、列表缩进、代码围栏与语言标注、表格列结构。
  - 不要编造笔记里没有的事实。

user:
  【当前笔记正文】<note>…</note>
  【本次请求】{指令}
  【选区】{选区原文}   ← 改写类必带
```

- **选区定位**：除选区原文，再带**选区前后各 200 字**上下文，避免「把第二段改正式些」歧义
- **上下文超限**：正文 > `notes_context_char_limit`（默认 12000）时降级为
  「标题 + 大纲 + 选区 + 命中关键词段落」，并在 UI 提示「已按相关片段裁剪上下文」；
  提供「发送全文」强制选项
- **参数**：temperature 改写/纠错 0.3、生成 0.7、问答 0.2；不传 `reasoningEffort`
  （与 `prompt_assistant.dart` 一致）；输出上限跟随 provider 的 `maxOutputTokensFor()`
- **模型**：默认 `AppState.appFeatureTarget`，笔记页可临时切换（临时值只作用于本次）
- **并发**：同一时间只允许一个 AI 请求在跑
- **取消**：`llm.CancelToken`；「停止」按钮与离开页面都 cancel
- **失败**：未配 provider/model → 顶部提示 + 跳「模型服务」页；请求失败 → 气泡内红字 +
  「重试」；模型返回空 → 「模型未返回有效内容」；离线 → 「网络不可用，请检查连接」

**diff 写回**

- `lib/util/line_diff.dart`：行级 LCS，输出 `equal/delete/insert` 三类行
- 弹层：宽 720，居中；红删 / 绿增 + 左侧竖条；未改行折叠为「省略 N 行」
- 底部：`[复制结果] [拒绝] [接受并应用]`
- **接受** → 写回**编辑器缓冲**（不直接落盘，仍走自动保存）→ 进撤销栈（`Ctrl+Z` 可撤销）
- **拒绝** → 只关闭，不改内容
- **任何 AI 写入都必过此弹层**（D5）

**AI 边栏两态**（D4）

- 展开 320px：Tab（改写/生成/问答）+ 模型选择 + 对话流 + 输入区
  - 输入区上方一行开关：**「包含全文」**（默认开；关掉则只发送选区）
  - Enter 发送 / Shift+Enter 换行
- 收起 44px 竖轨：AI 图标按钮（带「生成中」角标）+ 竖排「AI 助手」文字；点击展开
- 收起时笔记主区横向扩展占回 320px
- **生成中不允许收起**（收起按钮置灰）；正在跑的请求不中断
- 收起状态持久化（`SharedPreferences`）

**测试**（新建 `test/note_ai_test.dart`、`test/line_diff_test.dart`）

- `line_diff`：新增/删除/修改/无变化/空输入
- prompt 构造：包含选区前后 200 字；超限时降级并带提示标记
- diff 弹层：接受 → 缓冲区更新 + `Ctrl+Z` 可撤销；拒绝 → 内容不变
- 流式：中途 cancel → 不写回任何内容
- 未配模型：显示引导文案，不抛异常

**验收**：选中文本 → AI 改写 → diff → 接受 → 编辑器内容更新且可撤销。

---

### M4 · 移动端 + 打磨

**目标**：移动端底部 Tab `会话｜笔记`；笔记栈（列表 → 编辑 → AI 抽屉）；深色走查。

**修改文件**：`lib/ui/pages/home_page.dart`

- 窄屏（`maxWidth < 820`）当前是**直接渲染 `_Sidebar`**。改为：
  - 底部 Tab 条（`会话｜笔记`），**唯一**的工作区切换入口（D9）
  - **会话 Tab**：列表页（现有 `_Sidebar` 的会话树）→ 点会话进 `_MobileChatPage`（现有行为保留）
  - **笔记 Tab**：列表页 → 编辑页（上预览/下编辑，与桌面同一套）→ AI 底部抽屉
- AI 在移动端是**底部抽屉**（bottom sheet，高 70%，可上拉全屏），不是右侧边栏
- 「预览差异」在抽屉内以全屏路由打开，返回后回到抽屉原位

**打磨清单**

- 深色模式走查（代码块、diff 的红绿底、竖轨角标）
- 窄屏 820–1080 区间：侧栏 + 主区 + AI 边栏放不下时的降级（AI 边栏自动收起成竖轨）
- 空态文案与插画占位
- `flutter analyze lib test` + `flutter test` 全绿

---

## 5. 需要新建/修改的文件总表

**新增**

```
lib/models/note.dart
lib/data/xml/note_md.dart
lib/data/note_repository.dart
lib/ui/pages/notes_panel.dart
lib/ui/widgets/note_list.dart
lib/ui/widgets/note_editor.dart
lib/ui/widgets/note_ai_panel.dart
lib/ui/widgets/note_diff_dialog.dart
lib/util/line_diff.dart
test/note_storage_test.dart
test/sidebar_tab_test.dart
test/note_editor_test.dart
test/note_ai_test.dart
test/line_diff_test.dart
```

**修改**

```
lib/core/app_paths.dart            （notesDir / noteFile / ensureDirs）
lib/models/catalog_index.dart      （notes 桶 + version 4→5）
lib/data/index_repository.dart     （重建/校验/upsert/remove 笔记）
lib/state/app_state.dart           （notes 列表 + CRUD + refreshNotes）
lib/models/app_config.dart         （notes_context_char_limit）
lib/ui/pages/home_page.dart        （Tab 化侧栏 + 顶行按钮 + 移除新建会话行 + 移动端底部 Tab）
```

**不新增依赖**（保持 `pubspec.yaml` 不变）：diff 自己写行级 LCS；Markdown 渲染复用
`markdown_widget`；公式复用 `flutter_math_fork`。

---

## 6. 文档与记忆索引（收尾必做，勿忘）

| 文件 | 动作 |
| --- | --- |
| `FEATURES.md` | §1.1 目录布局加 `notes/`；§1.5 索引加 `notes` 桶与 version 5；§2 模型表加 `Note`；§9 UI 页面表加「笔记（侧栏 Tab）」；§7 功能表加笔记相关行 |
| `DESIGN.md` | 若有「界面结构」章节，补一句「笔记是左栏 Tab，不是独立路由」 |
| `.memory/ARCHITECTURE.md` | 加不变量：①笔记是左栏 Tab（不新增路由）②AI 写回必过 diff ③笔记用 Markdown 文件不是 XML |
| `.memory/GOTCHAS.md` | 记录实现中踩到的坑（尤其：widget test 定时器与 `runAsync` 交替；diff 撤销栈） |
| `.memory/ANNOTATIONS.yaml` | `features[]` 加一条 `notes`：files + contracts |
| `.memory/MAP.yaml` | **不要手改** → 跑 `dart run tool/gen_memory_index.dart` |
| `.memory/STATE.md` | 每个阶段结束都追加一节（做了什么 / 改了哪些文件 / 怎么验证 / 下一步 / 遗留问题） |
| 版本号 | 发版时同步 `pubspec.yaml` 的 `version:` 与 `lib/core/app_version.dart`（两处） |

---

## 7. 验证口径

```sh
flutter analyze lib test        # 必须 No issues found
flutter test                    # 必须全绿
dart run tool/gen_memory_index.dart --check   # 改了文件后必须 OK
```

手工验收路径（每个阶段都要能走通）：

1. 建项目 + 3 会话 → 切到「笔记」Tab → 新建笔记 → 写 Markdown（带公式、代码块、表格）
   → 预览与聊天里的观感一致 → 自动保存 → 重启 App 内容仍在
2. 侧栏断言：「新建会话」行消失；顶行「＋」在「↻」右侧；点「＋」在笔记 Tab 建笔记
3. 选中一段 → AI 改写 → diff → 接受 → 内容更新 → `Ctrl+Z` 撤销成功
4. AI 请求中途点「停止」→ 不写回任何内容
5. 删掉 `index.json` → 重启 → 笔记列表能自动重建
6. 用别的编辑器改了 `.md` → 回到 App → 收到变更提示

---

## 8. 风险清单

| 风险 | 应对 |
| --- | --- |
| 索引 version 4→5 导致老用户索引被重建 | 这是既定机制（防缺字段静默丢数据），照做；不要试图兼容老版本 |
| `markdownView` 被误改导致聊天消息渲染回归 | 预览只**调用**不改它；若要改渲染器，另开一次改动并跑 `test/markdown_copy_test.dart` |
| widget test 定时器假失败 | 假时钟（`pump`）与真实事件循环（`runAsync`）交替推进 |
| AI 静默覆盖正文 | diff 弹层是硬要求；写回先进缓冲再落盘 |
| 侧栏改造影响会话主流程 | M1 单独提交并单独测试；`test/home_flow_test.dart` 必须保持绿 |
| 移动端窄屏改造影响现有聊天 | 移动端改动放 M4 最后做，`test/home_flow_test.dart` 保持绿 |
| 外部编辑器改 `.md` 导致覆盖用户改动 | 保存前比 `mtime`，冲突弹窗让用户选 |

---

## 9. 对话提示词（新会话开场用）

> 下面这段可以直接复制给新会话。

```
请在项目 /mnt/kd/dop/pcr/aicoding/ds-xchat（XChat，Flutter）实施「带 AI 助手的 Markdown 笔记」功能。

先读这些（不要凭记忆做）：
1. docs/NOTES_IMPL_PLAN.md  —— 实施规划（唯一真相：阶段、文件、契约、验收）
2. docs/NOTES_AI_DESIGN.md  —— 功能设计
3. docs/mockups/notes_ui.html —— UI 设计图（浏览器打开对照）
4. .memory/STATE.md —— 上次到哪了
5. .memory/ARCHITECTURE.md + .memory/GOTCHAS.md —— 跨层不变量与已知坑

规则：
- 严格按 IMPLEMENT_PLAN 的 M0→M4 分阶段做，每个阶段单独完成、单独验证、单独更新 .memory/STATE.md。
- 阶段内不要跳步；发现计划与现有代码冲突时，先读代码确认，再小步调整实现（必要时回写计划文件并说明）。
- 不要新增第三方依赖：diff 自己写行级 LCS，Markdown 渲染复用 lib/ui/widgets/markdown_view.dart 的 markdownView()，公式复用 math_support.dart。
- 遵守 .memory/ARCHITECTURE.md 的跨层不变量：序列化只在 data 层；UI 不碰文件系统；全局状态只有 AppState；新字段必须能读旧文件；改 CatalogIndex.version 必须递增。
- 每个阶段结束必须跑：
  flutter analyze lib test        # No issues found
  flutter test                    # 全绿
  dart run tool/gen_memory_index.dart --check
  若本轮我要求测试，再跑；否则不主动代跑构建。
- 收尾更新 .memory/STATE.md（做了什么 / 改了哪些文件 / 怎么验证 / 下一步 / 遗留问题），
  必要时同步 ARCHITECTURE.md / GOTCHAS.md / ANNOTATIONS.yaml，MAP.yaml 用生成器刷新。
- 完成后提示我编译命令（flutter build apk / deb / windows），不要代跑打包。

已拍板、勿擅自改回：
- 笔记不新增路由，是左栏「会话 | 笔记」Tab 之一，主区随 Tab 切换。
- 中间栏只有一套布局：上预览 / 下编辑；不做「编辑/分屏/预览」模式切换。
- 下区高度三档 40% / 20% / 0%（收起），分隔条可拖动并吸附到最近档位。
- AI 边栏可展开（320px）/ 收起（44px 竖轨）；生成中不允许收起。
- AI 任何改正文都必须先过 diff 预览（接受/拒绝），接受后先进编辑器缓冲、可 Ctrl+Z。
- 笔记存 <root>/notes/<id>.md（Markdown + front-matter），不是 XML。
- 侧栏「新建会话」那一行移除，改为顶行图标按钮，紧挨「刷新会话列表」右侧；
  刷新按钮复用同一个 widget，只按 Tab 换 tooltip 与行为。
- 移动端底部 Tab「会话｜笔记」是唯一工作区切换入口，不保留抽屉双入口。
- AI 默认用「模型服务」页选的应用功能调用模型（AppState.appFeatureTarget）。

现在开始：先读上述文件，然后从 M0（地基层：Note 模型 / front-matter 序列化 / NoteRepository / 索引第 5 桶）动手，
做完后跑 analyze + test 并更新 .memory/STATE.md，再进入 M1。
```

---

## 10. 一句话验收

> 侧栏一个「笔记」Tab；笔记是 Markdown 文件；主区上预览下编辑、下区 40/20/0 三档；
> 右侧 AI 边栏 320↔44；AI 改写必过 diff；顶行「＋」紧挨「↻」；移动端底部 Tab 与桌面同语义；
> 索引能重建；`flutter analyze` 与 `flutter test` 全绿。
