/// The project memory index (`.memory/`) — protocol text and skeleton.
///
/// A project (a folder the user works in through XChat) can carry a small
/// memory index next to its code, so a *new* session can pick up where the
/// previous one stopped without re-reading the whole project.
///
/// The layout mirrors the index used by this repository:
///
/// ```
/// <project sandbox>/.memory/
///   README.md        entry point: routing table + start protocol + rules
///   STATE.md         where the last session stopped / what is next
///   ARCHITECTURE.md  structure, data flow, invariants
///   GOTCHAS.md       landmines and implicit contracts
///   MAP.yaml         facts: files, top-level symbols, dependencies, tests
///   PROMPT.md        the injection block and where it is used
/// ```
///
/// Rules of the house:
///   - the index is a **router**, not a copy of the content;
///   - one fact lives in exactly one place;
///   - code is referenced as `path + symbol`, never by line number.
library;

/// Directory name of the memory index, relative to the project sandbox.
const String kMemoryDirName = '.memory';

/// Stable marker of the injected protocol block.
///
/// It makes the injection **idempotent**: a prompt that already carries the
/// block (e.g. the stored prompt of a session that is re-created by
/// compressing another one) must not get a second copy.
const String kMemoryProtocolMarker = '【记忆索引 · .memory/】';

/// File names of the memory index, in the order they should be read.
const List<String> kMemoryFileNames = <String>[
  'README.md',
  'STATE.md',
  'ARCHITECTURE.md',
  'GOTCHAS.md',
  'MAP.yaml',
  'PROMPT.md',
];

/// The self-contained protocol block injected into a session's system prompt.
///
/// It must stand on its own: the agent should not have to read
/// `.memory/README.md` before it knows what to do with the index.
String memoryProtocolBlock({String projectName = ''}) {
  final who = projectName.trim().isEmpty ? '本项目' : '项目「$projectName」';
  return '''
$kMemoryProtocolMarker
$who 的工作目录里有一个 `.memory/` 记忆索引（相对「工作空间根目录」解析），用来接力上一次会话的上下文。
开始改动前：
1) 先读 `.memory/STATE.md`（上次做到哪、有没有半成品）；需要路由表或协议全文时再读 `.memory/README.md`。
2) 按任务查 `.memory/ARCHITECTURE.md`（结构与不变量）、`.memory/GOTCHAS.md`（已知坑）、
   `.memory/MAP.yaml`（文件/符号等事实）；索引不全时用 glob/grep 自查源码。
3) 索引只是路由，行为以源码为准；索引缺失就按同样的规则就地重建。
收尾时（改动落盘后）：
4) 更新 `.memory/STATE.md`：做了什么 / 改了哪些文件 / 怎么验证 / 下一步 / 遗留问题。
5) 结构、坑、事实有变化时同步 `.memory/ARCHITECTURE.md`、`.memory/GOTCHAS.md`、`.memory/MAP.yaml`。
前提：会话需启用 read_file / write_file（建议同时启用 glob / grep）工具；未启用时直接告诉用户去会话工具里开启，
不要假装已经更新过索引。
红线：一个事实只存一处；引用代码写「路径 + 符号名」，不写行号；不改动与本次任务无关的索引文件。
'''.trim();
}

/// The one-line pointer shown at the top of the prompt.
///
/// The full duties live at the end of the prompt (next to the conversation);
/// this line makes sure the agent notices the index *before* reading a long
/// hand-written prompt.
String memoryPointerLine({String projectName = ''}) {
  final who = projectName.trim().isEmpty ? '本项目' : '项目「$projectName」';
  // 注意：指针行不能重复 marker —— 「一次注入 = 一个 marker」是幂等判定的基础。
  return '记忆索引：$who 工作目录下的 `.memory/` —— 开始改动前先读 STATE.md，收尾时更新 STATE.md；'
      '协议全文见本提示词末尾。';
}

/// The skeleton files written when a memory index is initialised.
///
/// Every template is language-agnostic: a project may hold any kind of
/// source, so the facts layer (`MAP.yaml`) is maintained by the agent with
/// `glob`/`grep` instead of a language-specific generator.
Map<String, String> memorySkeletonTemplates({String projectName = ''}) {
  final name = projectName.trim().isEmpty ? '本项目' : projectName.trim();
  return <String, String>{
    'README.md': _readmeTemplate(name),
    'STATE.md': _stateTemplate(name),
    'ARCHITECTURE.md': _architectureTemplate(),
    'GOTCHAS.md': _gotchasTemplate(),
    'MAP.yaml': _mapTemplate(),
    'PROMPT.md': _promptTemplate(),
  };
}

String _readmeTemplate(String name) => '''
# $name 记忆索引 · 入口

本目录是本项目的**记忆索引**：让一个新会话（人或 AI）不必重读整个项目，
也能知道 **要改的东西在哪 · 有哪些不能碰的坑 · 上次做到哪**。

> 索引是**路由**，不是内容。
> 「代码在哪」→ `MAP.yaml`；「有哪些坑」→ `GOTCHAS.md`；「上次做到哪」→ `STATE.md`。
> 行为与实现**以源码为准**。

---

## 1. 目录

| 文件 | 谁写 | 内容 | 什么时候读 |
|---|---|---|---|
| `README.md` | 手写 | 本文件：入口、路由表、维护规则 | **每次会话第一个读** |
| `STATE.md` | 手写 | 上次做到哪、下一步、待验证 | **每次会话第二个读** |
| `ARCHITECTURE.md` | 手写 | 分层、数据流、跨层不变量 | 动结构或数据流前 |
| `GOTCHAS.md` | 手写 | 雷区与隐性契约 | 动高风险模块前 |
| `MAP.yaml` | 手写/生成 | 文件 / 顶层符号 / 模块依赖 / 测试清单 | 定位代码、评估影响面 |
| `PROMPT.md` | 手写 | 注入用系统提示词与适用场景 | 需要把协议复用到别处时 |

---

## 2. 新会话启动协议（给 AI）

1. 读 `STATE.md` —— 知道上一轮做到哪、有没有半成品。
2. 需要路由表或协议全文时读 `README.md`（本文件）。
3. 按任务查 `ARCHITECTURE.md` / `GOTCHAS.md` / `MAP.yaml` —— 确定**要动的文件集合**
   与影响面；索引不全时用 `glob`/`grep` 自查源码。
4. 动手改代码。

**红线**

- 索引是路由不是内容：它告诉你「在哪」，行为与实现以源码为准
- 引用代码位置用「文件路径 + 符号名」，**不写行号**（代码一改就失效）
- 一个事实只存一处；不要在索引里复制大段源码或设计文档

---

## 3. 路由表：我想改 X → 去哪

| 任务 | 先读 | 主要文件 |
|---|---|---|
| （按本项目实际结构补充一行） | | |

---

## 4. 维护规则

**收尾流程（改完代码后）**

1. 更新 `STATE.md`：做了什么 / 改了什么文件 / 怎么验证 / 下一步 / 遗留问题。
2. 新增 / 删除 / 移动了文件，或模块职责变了 → 同步 `MAP.yaml`。
3. 结构或数据流变了 → 同步 `ARCHITECTURE.md`。
4. 踩到坑、发现隐性契约 → 追加 `GOTCHAS.md`。
''';

String _stateTemplate(String name) => '''
# STATE — 进度交接

> **每次会话结束前必须更新本文件。** 这是新会话唯一的「上次到哪了」来源。
> 格式保持：做了什么 / 改了什么文件 / 怎么验证 / 下一步 / 遗留问题。

## 当前快照

| 项 | 值 |
|---|---|
| 项目 | $name |
| 记忆索引 | `.memory/`（本文件 + README / ARCHITECTURE / GOTCHAS / MAP / PROMPT） |
| 最近更新 | （待填） |

## 遗留问题

- （暂无）

---

## 模板（复制到新一节）

## YYYY-MM-DD · 本次标题

**做了什么**

**改了什么文件**

**怎么验证**

**下一步**

**遗留问题**
''';

String _architectureTemplate() => '''
# 架构速览（索引层）

> 本文只写**结构与不变量**。文件级事实见 `MAP.yaml`，坑见 `GOTCHAS.md`。

## 1. 分层与依赖方向

（待填：模块 → 依赖方向，尽量画成简单的箭头图）

## 2. 关键数据流

（待填：一次典型操作从头到尾经过哪些文件）

## 3. 跨层不变量（改代码前先确认自己没破坏）

1. （待填）
''';

String _gotchasTemplate() => '''
# 雷区与隐性契约

> 只记**踩过的坑**与**读代码看不出来的契约**。
> 每条按「现象 → 根因 → 修法 / 推论」写。

## 1. （暂无）

<!--
示例：
## 2. 复制粘贴丢换行
- 现象：选中 Markdown 消息复制，换行消失。
- 根因：富文本节点用 WidgetSpan 承载，剪贴板只拿到纯文本。
- 修法：复制前把 WidgetSpan 降级为纯文本再写入剪贴板。
-->
''';

String _mapTemplate() => '''
# .memory/MAP.yaml — 事实层
#
# 这里只有**机器可推导的事实**：文件、顶层符号、模块依赖、测试清单。
# 人的判断（职责、风险、注意事项、功能→文件映射）写在 ARCHITECTURE.md。
#
# 没有生成器时用 glob/grep 手工维护，但必须与磁盘一致。
#
# 建议结构：
# meta:
#   updated_at: "YYYY-MM-DD"
# modules:
#   - id: <模块名>
#     path: <相对路径>
#     files:
#       - path: <相对路径>
#         symbols: [Name1, Name2]
# tests:
#   - path: <相对路径>
#     cases: <数量>

meta:
  updated_at: ""
modules: []
tests: []
''';

String _promptTemplate() => '''
# 注入用系统提示词

## 一句话结论

- **协议正文的权威出处是 `.memory/README.md` 的 §2 与 §4**，别处不复制副本。
- **注入块**（下方）= 一段自包含的提示词，贴进任何 agent 的系统提示词即可。

---

## 注入块

```
${memoryProtocolBlock()}
```

---

## 场景对照

| 场景 | 做法 | 注意 |
|---|---|---|
| 本应用内新建会话 | 项目启用记忆时自动注入 | 系统提示词首行是「工作空间根目录: <绝对路径>」，`.memory/` 相对它解析 |
| 别的 harness | 贴上面的注入块 | 不要另抄一份协议正文 |

---

## 层次职责

| 层 | 文件 | 谁写 | 会不会过期 |
|---|---|---|---|
| 注入块 + 场景 | `PROMPT.md`（本文件） | 手写，短 | 随场景变 |
| **协议正文** | `README.md` §2 + §4 | 手写 | 改协议只改这里 |
| 事实 | `MAP.yaml` | 手写/生成 | 会 —— 与代码不一致时要更新 |
| 结构 | `ARCHITECTURE.md` | 手写 | 慢变 |
| 坑 | `GOTCHAS.md` | 手写 | 只增不减 |
| 进度 | `STATE.md` | 每次会话 | 总是最新 |
''';
