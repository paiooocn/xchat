# 外部 Markdown 文件：打开文件 / 打开目录 · 设计方案（待拍板）

> 状态：**已实现（E0–E3，2026-11-04）**。实现记录见 `.memory/STATE.md`。
> 前置阅读：`docs/NOTES_AI_DESIGN.md`、`docs/NOTES_IMPL_PLAN.md`、
> `lib/data/xml/note_md.dart`、`lib/ui/pages/notes_panel.dart`。

## 1. 需求

1. **打开外部 md 文件**：从磁盘任意位置挑一个 `.md` 文件，在笔记主区打开查看。
2. **打开文件目录**：选一个目录后，把它**目录内的 md 文件**列在**笔记边栏**，
   点击即在主区查看。
3. **外部 md 文件默认只读**：必须显式「开启编辑」后才能修改内容（修改写回**原文件**）。

## 2. 范围

**做**

- 打开单个 md 文件、打开一个目录并列出目录内 md 文件（递归 ≤ 3 层）。
- 外部文件的预览 / 只读保护 / 开启编辑后写回原文件 / 与磁盘改动冲突的确认。
- 外部文件复用现有编辑区（上预览 / 下编辑、三档高度、AI 助手、diff 写回）。

**不做（一期）**

- 外部文件的 front-matter 注入、标签 / 置顶 / 归档 / 删除（这些是「内部笔记」的语义，
  外部文件归用户自己的工具管）。
- 文件系统实时监听（用刷新按钮 + 打开时比对 mtime）。
- 多目录同时打开（一期单目录，切目录即替换；见 §13-D3）。
- 外部图片附件的相对路径改写、重命名外部文件。
- 新建文件到外部目录。

## 3. 关键设计结论

| # | 结论 | 理由 |
|---|---|---|
| D1 | 外部文件**不写 front-matter、不进 `index.json`** | 写头会污染用户文件；索引是「内部笔记」的元数据缓存 |
| D2 | 外部文件正文**逐字读写**（保留 CRLF / BOM，见 §8.4） | 用户的其他工具可能依赖行尾 |
| D3 | 默认**只读**，需显式开启编辑 | 需求原文；避免误改用户文件 |
| D4 | 外部文件**复用** `NotesPanel` / `NoteEditor`，不另开路由 | 预览/分屏/AI 全是现成的，另写一套必然分叉 |
| D5 | 侧栏外部区放在笔记列表**最上方**，可折叠 | 「刚打开的目录」是当前焦点；折叠后不挤压内部笔记 |
| D6 | 一期**单目录 + 单文件**（内存 + prefs 恢复） | 需求是单数；多目录是后续增强 |
| D7 | 内部笔记目录（`<root>/notes/`）里的文件**按内部笔记打开**，不套只读壳 | 同一文件不能有两个真相 |
| D8 | 只读时**强制 0 档**（纯预览），档位控件禁用 | 一眼看出「现在不能改」，比灰掉的输入框清楚 |

## 4. 数据模型（`lib/models/external_doc.dart`，新增）

```dart
/// 侧栏里的一个候选 md 文件（只来自目录扫描 / 单文件打开，不读正文）。
class ExternalMdEntry {
  final String path;          // 绝对路径（唯一键）
  final String name;          // 文件名（含扩展名）
  final String relativeDir;   // 相对根目录的目录部分（'' = 根层），用来分组/显示
  final DateTime? modifiedAt;
  final int sizeBytes;
}

/// 真正打开的那个文件（已读入正文）。
class ExternalDoc {
  final String path;
  final String name;
  bool readOnly;              // 由 UI 层控制，默认 true
  String body;                // 已规范化的正文（LF，见 §8.4）
  DateTime? loadedMtime;      // 打开时的 mtime，用于外部改动检测
  bool crlf;                  // 原文件是 CRLF 行尾（写回时还原）
  bool bom;                   // 原文件带 UTF-8 BOM（写回时还原）
  String? loadError;          // 读失败原因（不存在 / 权限 / 过大 / 非文本）
}
```

**与 `Note` 的关系**：`ExternalDoc` **不复用** `Note`。`Note` 携带 front-matter 语义
（`id/tags/pinned/archived`），而外部文件没有这些，混用会让序列化层出现
「要不要写头」的分支（违反 §5 不变量 17「序列化只在 data 层」的清晰性）。

## 5. 数据层（`lib/data/external_doc_repository.dart`，新增）

```dart
class ExternalDocRepository {
  const ExternalDocRepository();

  /// 扫描目录内 md 文件（递归，最多 maxDepth 层，最多 maxFiles 个）。
  /// 跳过：隐藏目录/文件（`.` 开头）、符号链接目录、无读权限的目录。
  Future<ExternalMdScan> scanDirectory(
    String dir, {
    int maxDepth = 3,
    int maxFiles = 800,
  });

  /// 读一个 md 文件：UTF-8（allowMalformed）、去 BOM、记录换行风格与 mtime。
  /// > kExternalDocMaxBytes（默认 4 MiB）→ 不读，返回 loadError（用外部编辑器打开）。
  Future<ExternalDoc> read(String path);

  /// 逐字写回（无 front-matter），原子写；写后回填 mtime。
  Future<void> write(String path, String body);

  Future<DateTime?> modifiedAt(String path);
  Future<bool> exists(String path);
  Future<String> canonicalize(String path);   // 解析绝对路径 + 大小写/符号链接
}

class ExternalMdScan {
  final String root;
  final List<ExternalMdEntry> files;   // 按 relativeDir + name 排序
  final bool truncated;                // 命中 maxFiles / maxDepth
  final String? error;
}
```

- 扫描**只 `stat` 不读内容**：标题显示用文件名（不为了标题去读 800 个文件）。
- 扩展名接受 `.md` / `.markdown`（大小写不敏感）。
- 原子写复用 `NoteRepository._writeAtomic` 的同一套逻辑 → **抽成
  `lib/data/atomic_file.dart` 的 `writeAtomic(path, content)`**，两个仓库共用
  （不改行为，只是搬家；`NoteRepository` 内部调用点替换）。
- 平台守卫：`Platform.isAndroid` 时不提供目录扫描的「写回」（SAF 路径不一定可写），
  见 §9。

## 6. 状态层（`lib/state/app_state.dart` 扩展）

```dart
// 外部文件区（不参与 index.json）
ExternalDocRepository externalDocRepository;      // 新增 late final
String? externalRoot;                             // 当前打开的目录（null = 未打开）
ExternalMdScan? externalScan;                     // 最近一次扫描结果
String? externalFile;                             // 单独打开的文件的绝对路径（null = 无）

Future<void> openExternalRoot(String dir);        // 扫描 + 落 prefs
Future<void> refreshExternalRoot();               // 重新扫描
void closeExternalRoot();                         // 关闭目录（清 prefs）
Future<void> openExternalFile(String path);       // 单独打开（记忆路径 + 落 prefs）
void closeExternalFile();

Future<ExternalDoc> readExternalDoc(String path);
Future<bool> saveExternalDoc(String path, String body);  // 写回 + 返回是否成功
Future<DateTime?> externalDocModifiedAt(String path);
```

- 持久化：`SharedPreferences` → `notes_external_root`（启动恢复并扫描）、
  `notes_external_file`（只用于「最近打开」提示，**不自动打开**，避免启动即报错）。
- 冲突规则：若 `path` 落在 `<root>/notes/` 内且是现有内部笔记 → `openExternalFile`
  直接返回内部笔记 id，UI 切到内部笔记视图（D7）。
- `AppState` 仍是唯一全局状态（不变量 3）；外部区状态只是几字段 + 几个方法。

## 7. UI 设计

### 7.1 侧栏（`lib/ui/widgets/note_list.dart`）

```
┌ 笔记（左栏，宽 280） ────────────────────────┐
│ [🔍 搜索笔记 / 外部文件名]                   │  ← 搜索框对两者同时生效
│ ── 外部文件 ──────────────  [⤢ 折叠]        │  ← 新区块，最上方
│ 📁 docs          12 个 md     [↻] [✕]      │  ← 目录头行（可点开/收起）
│   README.md                                 │
│   设计/接口.md                               │
│   设计/数据流.md                             │
│ ⧉ 单独打开：tmp/draft.md            [✕]     │  ← 仅当单独打开的文件不在该目录树内
│ ── 置顶 ─────────────────────────────────   │
│ ...
```

- **未打开目录时**：外部区只显示两行入口（`⧉ 打开 md 文件…` / `📁 打开文件夹…`），
  高度约 64px，不抢空间。
- **分组显示**：`relativeDir` 非空时，第二行用 `onSurfaceVariant` 小字显示相对目录；
  组内按文件名排序；最多渲染 `maxFiles` 个，超出显示「还有 N 个未显示 · 缩小目录范围」。
- **目录头行**：文件夹名（tooltip 显示完整路径）+ 文件数 + `↻` 刷新 + `✕` 关闭目录。
- **搜索**：同一个搜索框过滤外部文件（匹配 `name` / `relativeDir`）与内部笔记。
- **空态调整**（重要）：现在「内部无笔记」会整列替换成空态卡片，会把外部区一并吃掉
  → 改为：**只要外部区有内容，就渲染列表**；空态文案只在「内部与外部都为空」时出现。
- **移动端**：同一套列表（`NoteList` 在窄屏抽屉里），点击外部文件 → 压栈
  `_MobileNotePage(externalPath: ...)`。

### 7.2 入口（`lib/ui/pages/home_page.dart` 顶行）

笔记 Tab 顶行右侧变成：

```
[📂 打开 ▾] [↻ 刷新] [＋ 新建] [⌂ 首页]
```

`📂 打开` 是 `PopupMenuButton`：

- `打开 md 文件…` → `FilePicker.pickFiles(type: custom, allowedExtensions: ['md','markdown'])`
- `打开文件夹…` → `FilePicker.getDirectoryPath()`
- `手动输入路径…` → 复用现有「手动输入路径」对话框（跨平台兜底，Android 用 SAF 失败时用这个）
- 已打开目录时追加：`刷新目录`、`关闭目录`

`↻ 刷新`（笔记 Tab 已有的按钮）语义扩展为：刷新内部笔记列表 **+ 重新扫描外部目录**。

### 7.3 主区（`lib/ui/pages/notes_panel.dart`）

`NotesPanel` 增加可选参数 `externalPath`（与 `noteId` 互斥，`externalPath` 优先）。

**只读态（打开外部文件的默认态）**

```
┌ 46px 顶栏 ─────────────────────────────────────────────────┐
│ 📄 interface.md       [只读]      [👁 开启编辑]  [AI] [⋮]  │
├────────────────────────────────────────────────────────────┤
│                       （预览，占满）                        │
├─ 30px 状态条 ──────────────────────────────────────────────┤
│ 🔒 只读 · 外部文件 · 2.1 KB · /home/u/docs/interface.md    │
└────────────────────────────────────────────────────────────┘
```

- 高度档位控件**隐藏**（只读时编辑区不存在，D8）；顶栏显示 `只读` 徽标。
- 状态条：锁图标 + `只读 · 外部文件` + 大小 + 完整路径（点击复制路径）。
- `⋮` 菜单（只读）：`重新加载` · `复制路径` · `在文件管理器中显示` ·
  `用编辑工具打开` · `开启编辑`。**没有**重命名 / 标签 / 置顶 / 归档 / 删除。
- AI 边栏照常可用：问答 / 复制不受影响；**改写的「应用」按钮在只读时被拦下**，
  提示「先开启编辑」。（实现：`_applyAiResult` 开头判断 `readOnly`。）

**编辑态（点「开启编辑」后）**

- 首次确认对话框（§8.2 通过后）→ `readOnly = false`：
  顶栏 `只读` 徽标变成 `编辑中`（primary 色），出现档位控件（回到用户上次档位 40/20/0）、
  编辑器工具栏、「结束编辑」按钮。
- 自动保存沿用现有 800ms 防抖；`Ctrl+S` 同内部笔记；
  状态条：`已保存 / 保存中… / 未保存 · 保存失败` + `写回原文件` 提示。
- 「结束编辑」= 先保存，再回到只读态（失败则停留在编辑态并提示）。
- 外部改动检测复用现有 `_confirmExternalChange` 弹窗，文案改为「磁盘上的文件已变更」。

**内部笔记视图**：完全不变（现有代码路径）。

### 7.4 `NoteEditor` 的小改动（`lib/ui/widgets/note_editor.dart`）

- 新增 `bool readOnly`（默认 false）：
  - `readOnly == true`：不渲染工具栏与分隔条，只渲染预览；`TextField` 不创建
    （省内存也省误触）。容器上不管，由 `NotesPanel` 传 `splitRatio: 0`。
  - 工具栏的 `extraActions` 在只读态不渲染。
- 其余（分隔条吸附、快捷键、`NoteEditorController`）不动。

## 8. 写回安全（这是本功能的主要风险面）

### 8.1 三道闸

1. **默认只读**：打开即预览，不产生任何写盘。
2. **开启编辑需确认**（§8.2）。
3. **写回前比对 mtime**：与内部笔记同一套冲突弹窗；外部文件冲突概率更高
   （用户可能在 VSCode 里同时开着），文案点明「覆盖磁盘上的最新内容」。

### 8.2 「开启编辑」确认对话框

```
标题：开启编辑
正文：改动会直接写入原文件，可能覆盖其他工具（如 VSCode / Typora）的修改。
      /home/u/docs/interface.md
     [取消]  [开启编辑]
```

**一次会话内每文件只弹一次**（记住 `Set<String> _editConfirmed`，切文件不重置、
关面板重置）。理由：每次切都弹会烦，且第一次已经明确风险。
（可拍板改为：每次都弹 / 永不弹只留状态条提示，见 §13-D4）

### 8.3 失败与异常

| 情况 | 行为 |
|---|---|
| 文件被删除（打开期间） | 保存时 `exists == false` → 提示「文件已不存在，另存为内部笔记？」→ `[放弃] [另存为笔记]` |
| 无写权限 / 只读挂载 | 保存失败 → 状态条 `保存失败` + 弹一次错误详情，保持编辑态（不丢内存内容） |
| 目录被移除 / U 盘拔出 | 同上（`FileSystemException` 兜底） |
| 文件超 4 MiB | 不读正文，主区显示「文件过大（3.2 MB），请用外部编辑器打开」+ 提供按钮 |
| 疑似二进制（含 NUL 字节） | 同样拒绝预览，提示用外部编辑器 |

### 8.4 编码与行尾

- 读：UTF-8（`allowMalformed: true`，避免一个坏字节整篇失败）；去掉 BOM 并记 `bom`。
- 若正文含 `\r\n`：**规范化成 `\n` 供编辑**，记 `crlf = true`；写回时统一转回 `\r\n`。
  这样 TextField 不会把 `\r` 当普通字符显示，同时不破坏原文件行尾。
- 写：`bom` 为真则写回 BOM。

### 8.5 与内部笔记的边界（D7）

- 目标路径落在 `<root>/notes/` 且对应一篇存在的内部笔记 → 直接以**内部笔记**打开
  （带标签/置顶等完整能力），不进入只读壳。
- 外部目录扫描把 `notes/` 也扫进来时，这些文件在侧栏标记为「本机笔记」
  图标（点击仍走内部笔记视图）。

## 9. 平台差异与限制

| 平台 | 打开 md 文件 | 打开文件夹 |
|---|---|---|
| Linux / macOS / Windows | ✅ `FilePicker.pickFiles` | ✅ `FilePicker.getDirectoryPath`，写回可用 |
| Android | ✅ 但 `file_picker` 可能返回**缓存副本**路径 → 写回的是副本，不能回写原文件。**检测到路径在应用缓存目录内时，强制只读 + 提示**（不允许开启编辑） | ⚠️ SAF 返回的树路径通常不可直接读写 → 一期**不提供**（菜单里置灰 + 「手动输入路径」兜底，仅当用户能给出真实路径） |
| iOS | 同 Android 的缓存副本限制 | 一期不提供 |

- 判断「缓存副本」：路径前缀命中 `getTemporaryDirectory()` / 安卓 `file_picker`
  缓存目录 → `writableExternal = false`，状态条显示「来自其他应用的副本，无法写回」。
- 「手动输入路径」对话框复用 `home_page.dart` 现有的 `_askPath` 模式（抽成公共
  `askPathDialog`，两处共用）。

## 10. 实施阶段（拍板后执行）

**E0 数据层（无 UI）**

- 新增 `lib/models/external_doc.dart`、`lib/data/external_doc_repository.dart`、
  `lib/data/atomic_file.dart`（迁出 `_writeAtomic`）。
- `AppState` 加仓储 + `externalRoot / externalScan / externalFile` + 方法 + prefs 恢复。
- 测试：`test/external_doc_test.dart`（扫描/过滤/深度/上限、编码/BOM/CRLF、
  原子写、超大文件、notesDir 冲突、prefs 恢复）。

**E1 侧栏 + 入口**

- `note_list.dart` 新增外部区（折叠/刷新/关闭/搜索兼容/空态修正）。
- `home_page.dart` 顶行 `📂 打开 ▾` 菜单 + 手动输入路径对话框抽取；
  `↻ 刷新` 扩展；选择态从「noteId」扩到「noteId | externalPath」；
  移动端 `_MobileNotePage` 支持 `externalPath`。
- 测试：`test/external_doc_ui_test.dart`（菜单项、目录列表渲染、点击切换主区、关闭目录）。

**E2 只读主区**

- `NotesPanel(externalPath:)` 加载分支；只读布局（徽标 / 无档位 / 状态条 / 菜单差异）；
  `NoteEditor(readOnly:)`；AI「应用」拦截。
- 测试：只读时无 TextField / 无工具栏、状态条含「只读」、AI 应用被拦并提示。

**E3 开启编辑 + 写回**

- 确认对话框、`readOnly` 切换、自动保存、mtime 冲突、失败与「另存为笔记」分支、
  缓存副本禁写。
- 测试：开启编辑后出现编辑器、改动写回原文件且**不含 front-matter**、CRLF 还原、
  只读时磁盘文件字节不变、冲突弹窗两条分支。

**收尾**

- `FEATURES.md` §7.1 补「外部 md 文件」；`.memory/ARCHITECTURE.md` 加不变量
  （外部文件不写头/不进索引/默认只读）；`.memory/GOTCHAS.md` 加
  （`file_picker` Android 缓存副本、CRLF/BOM、目录扫描性能）；
  `.memory/MAP.yaml` 用 `dart run tool/gen_memory_index.dart` 刷新；`.memory/STATE.md`。

## 11. 验收清单

1. 打开单个 md → 主区只读预览，磁盘文件 **字节不变**。
2. 打开目录 → 侧栏列出其内全部 md（≤3 层、跳过隐藏），点击逐个可看。
3. 点「开启编辑」→ 确认后出现编辑器；改字 800ms 后原文件被更新，
   且**没有**新增 `---` front-matter 头，CRLF 文件仍是 CRLF。
4. 编辑期间用 VSCode 改同一文件 → 下次自动保存弹冲突，两条分支都按预期。
5. 关闭目录 → 侧栏外部区回到两个入口行；内部笔记列表不受影响。
6. Android 上打开来自其他应用的文件 → 只读且「开启编辑」被禁用（副本不可写）。
7. `flutter analyze lib test` 无告警；`flutter test` 全绿。

## 12. 风险清单

| 风险 | 缓解 |
|---|---|
| 误写用户文件 | 默认只读 + 开启编辑确认 + mtime 冲突拦截 + 原子写 |
| 侧栏扫描卡顿（大目录/网络盘） | 深度 ≤3、文件 ≤800、只 stat 不读内容、扫描异步 + 结果截断提示 |
| 预览渲染超大 Markdown 卡顿 | 4 MiB 上限直接拒绝；预览 300ms 防抖（既有） |
| 与内部笔记双真相 | D7：`notes/` 下的文件一律走内部笔记 |
| 外部文件路径失效 | 所有读都 catch，主区显示「文件已不存在」+ 「重新选择」 |

## 13. 待拍板项

- **D1（默认取值：做）** 外部文件一律不写 front-matter —— 确认不希望在外部文件里
  携带 `id/tags` 元数据。
- **D2（默认：递归 ≤3 层）** 目录只列顶层，还是列子目录？（默认递归 3 层）
- **D3（默认：单目录）** 是否需要同时打开多个目录（多根并列）？
- **D4（默认：每文件每会话弹一次确认）** 「开启编辑」的确认频率：
  每次开启都弹 / 每文件一次 / 不弹只显示状态条。
- **D5（默认：恢复目录、不自动打开单文件）** 重启后是否自动恢复上次的目录/文件？
- **D6（默认：不做）** 是否要 `Ctrl+O` 快捷键打开 md 文件 / `Ctrl+Shift+O` 打开目录？
- **D7（默认：不做）** 外部文件的「另存为内部笔记」入口是否常驻菜单？
  （异常兜底里已有一条「另存为笔记」，是否升级为常规功能）
