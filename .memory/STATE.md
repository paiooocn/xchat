# STATE — 进度交接

> **每次会话结束前必须更新本文件。** 这是新会话唯一的"上次到哪了"来源。
> 格式保持：做了什么 / 改了什么文件 / 怎么验证 / 下一步 / 遗留问题。

## 当前快照

| 项 | 值 |
|---|---|
| 应用版本 | 0.5.8 (build 1) |
| 最近提交 | `7084a34` — release: v0.5.8 修复代码围栏之后的文本无法选中复制 |
| 工作区 | 有未提交改动（提示词三段式改造，见下节） |
| 记忆索引 | 已建立并在用：`.memory/`（7 个文件）+ `tool/gen_memory_index.dart` |

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
