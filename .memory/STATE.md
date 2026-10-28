# STATE — 进度交接

> **每次会话结束前必须更新本文件。** 这是新会话唯一的"上次到哪了"来源。
> 格式保持：做了什么 / 改了什么文件 / 怎么验证 / 下一步 / 遗留问题。

## 当前快照

| 项 | 值 |
|---|---|
| 应用版本 | 0.6.0 (build 1) |
| 最近提交 | 本次：release: v0.6.0 项目记忆索引（.memory/）机制（上一提交 `9ff395b` v0.5.10） |
| 工作区 | 干净（本次改动已提交） |
| 记忆索引 | 已建立并在用：`.memory/`（7 个文件）+ `tool/gen_memory_index.dart` |

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
