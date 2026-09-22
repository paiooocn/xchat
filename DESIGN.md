# XChat — 基于 Flutter 的 LLM Agent 跨平台应用 · 设计文档

> 版本 v1（待确认）
> 目标平台：Android / iOS / macOS / Windows / Linux
> 数据目录：`Documents/XChat/`

---

## 1. 概述

XChat 是一个 **Flutter 原生 GUI**（非 WebView）的 LLM Agent 客户端，通过
**OpenAI 兼容 API** 连接各类大模型，Agent 采用 **ReAct（Reasoning + Acting）**
模式，具备工具调用、思考链（thinking）展示与回发、Token 用量统计、XML 会话持久化。

核心设计约束（来自需求）：

1. 跨平台 Flutter，单一代码库。
2. 会话以 **XML** 文件保存；根元素 `chat`，属性 `sandbox` 记录会话文件目录；
   文件名为会话 id（UUID）。
3. `meta` 子元素保存元信息；其余子元素对应会话 JSON 字段。
4. 文本一律使用 **CDATA**，不做转义。
5. 兼容 `reasoning_content`（mimo/kimi/glm/deepseek）与 `<think>`（minimax）
   两种思考模式的**显示与回发**。
6. 传入并采集 `usage`，按 `input/output/cache` 统计；单次写入 `assistant`
   属性，累计写入 `system` 属性，`context` 也写入 `system`。
7. 单次会话有**工具调用次数上限**，达到上限后**自动发送一条对话**判断是否继续调用工具。
8. 会话功能：**创建向导 / 会话模板 / 编辑工具打开 / 最近一次 user 编辑（重发）/ 克隆**。

---

## 2. 技术栈

| 层         | 选型                                                       | 说明                                                                               |
| ---------- | ---------------------------------------------------------- | ---------------------------------------------------------------------------------- |
| 框架       | Flutter 3.x（Dart SDK `^3.12`）                            | 原生渲染，全平台                                                                   |
| 状态管理   | `provider` (ChangeNotifier)                                | 轻量、成熟、易于测试                                                               |
| LLM 客户端 | **内置 `llm_api` 包**（vendor 自本机 `dart-llmapi`）       | 已实现 OpenAI 兼容流式、`reasoning_content`/`<think>` 路由、usage 归一化、工具循环 |
| XML        | `xml` (`^6.5`)                                             | `XmlBuilder` + `cdata()` 原生支持 CDATA                                            |
| UUID       | `uuid` (`^4.5`)                                            | 会话 id                                                                            |
| 路径       | `path_provider` + `path`                                   | `Documents/XChat`                                                                  |
| Markdown   | `markdown_widget` + `highlight`                            | 代码高亮、表格、列表                                                               |
| 配置持久化 | `config.json`（+ 可选 `flutter_secure_storage` 存 apiKey） | 见 §4                                                                              |
| 外部编辑器 | `process_run` / `Process.start`                            | 桌面端「编辑工具打开会话」                                                         |
| 国际化     | `intl` + 内置 zh/en 文案（可选）                           |                                                                                    |

> `llm_api` 将以源码形式 vendor 到 `packages/llm_api/`，保证仓库自包含、可编译。
> 应用层通过 `OutboundAdapter` 补齐「`<think>` 回发」能力（见 §7）。

---

## 3. 目录结构

```
ds-xchat/
├── pubspec.yaml
├── DESIGN.md
├── packages/
│   └── llm_api/                      # vendored dart-llmapi（原样，少量扩展见 §7）
├── lib/
│   ├── main.dart                     # 入口：初始化路径/配置/仓库
│   ├── app.dart                      # MaterialApp + 路由 + 主题 + i18n
│   ├── core/
│   │   ├── app_paths.dart            # Documents/XChat 解析与目录创建
│   │   ├── ids.dart                  # uuid 生成
│   │   └── json_utils.dart
│   ├── models/
│   │   ├── session.dart              # Session（含 JSON round-trip）
│   │   ├── session_message.dart      # 统一消息模型（role/content/reasoning/toolCalls/usage）
│   │   ├── token_usage.dart          # input/output/cache
│   │   ├── session_meta.dart         # id/created_at/updated_at/tool_calls/tool_calls_limit
│   │   ├── session_params.dart       # temperature/max_tokens/thinking/reasoning_effort...
│   │   ├── provider_config.dart
│   │   ├── session_template.dart
│   │   └── app_config.dart
│   ├── data/
│   │   ├── xml/
│   │   │   ├── cdata.dart            # buildCdata / readCdata 工具
│   │   │   ├── session_xml.dart      # Session <-> XML（核心）
│   │   │   └── template_xml.dart     # Template <-> XML
│   │   ├── session_repository.dart   # 列表/读/写/删除/克隆/重发
│   │   ├── template_repository.dart
│   │   └── config_repository.dart
│   ├── llm/
│   │   ├── llm_presets.dart          # deepseek/kimi/glm/mimo/minimax/qwen/openai/openrouter...
│   │   ├── llm_factory.dart          # ProviderConfig -> LlmProvider
│   │   └── outbound_adapter.dart     # 思考回发适配（reasoning_content vs <think>）
│   ├── agent/
│   │   ├── agent_engine.dart         # ReAct 主循环 + 工具次数预算 + 自动续判
│   │   ├── agent_events.dart         # 流式事件（UI 消费）
│   │   ├── token_tracker.dart        # usage 写入 assistant / system
│   │   └── tools/
│   │       ├── tool_registry.dart
│   │       ├── path_guard.dart       # 沙箱路径校验
│   │       ├── fs_tools.dart         # read/write/edit/list/glob
│   │       ├── shell_tool.dart       # 桌面端命令执行
│   │       ├── http_tool.dart        # http_fetch / web_search
│   │       └── datetime_tool.dart
│   ├── session/
│   │   ├── session_controller.dart   # 当前会话的运行时状态（ChangeNotifier）
│   │   └── session_ops.dart          # clone/editLastUser/rename/tags/import/export
│   ├── ui/
│   │   ├── pages/
│   │   │   ├── home_page.dart        # 会话列表 + 主聊天（自适应）
│   │   │   ├── chat_page.dart
│   │   │   ├── sessions_page.dart
│   │   │   ├── template_page.dart
│   │   │   ├── provider_page.dart
│   │   │   ├── settings_page.dart
│   │   │   ├── xml_editor_page.dart  # 内置 XML 编辑器（移动端/无外部编辑器）
│   │   │   └── session_wizard_page.dart
│   │   ├── widgets/
│   │   │   ├── message_bubble.dart
│   │   │   ├── thinking_block.dart   # 可折叠思考块
│   │   │   ├── tool_call_block.dart  # 工具调用 + 结果
│   │   │   ├── usage_badge.dart      # 单条/累计 token 角标
│   │   │   ├── context_bar.dart      # 上下文占用条
│   │   │   ├── input_area.dart
│   │   │   └── session_list_tile.dart
│   │   └── theme/app_theme.dart
│   └── util/
│       ├── editor_launcher.dart      # 调用外部编辑器
│       └── logger.dart
├── test/
│   ├── session_xml_test.dart         # XML round-trip（含 CDATA/思考/usage）
│   ├── session_ops_test.dart         # clone / editLastUser
│   └── agent_budget_test.dart        # 工具次数上限 + 自动续判
├── android/ ios/ macos/ windows/ linux/
```

---

## 4. 数据目录与文件组织

根目录固定为 **`Documents/XChat/`**（`path_provider.getApplicationDocumentsDirectory()` + `XChat`）。

```
Documents/XChat/
├── config.json          # 应用配置（provider、默认参数、编辑器命令、主题、语言…）
├── models_dev.json      # models.dev 目录快照（提供商/模型元数据缓存）
├── sessions/            # 默认 sandbox：会话 XML 文件（<uuid>.xml）
│   ├── 550e8400-....xml
│   └── ...
└── templates/           # 会话模板（<template-id>.xml）
    └── ...
```

说明：

- `sessions/` 即会话根 `chat` 的 `sandbox` 属性值。每个会话文件**自带** `sandbox`，
  使其可被独立打开/导入到任意目录，符合「根元素 sandbox 为存放会话文件的沙箱目录」。
- 会话文件路径 = `sandbox` + `/` + `id` + `.xml`。
- 平台差异：桌面（macOS/Windows/Linux）`getApplicationDocumentsDirectory()` 返回真实
  `~/Documents`；Android 返回 App 私有目录，若用户授权外部存储则优先用共享
  `Documents/XChat`，否则回退 App 目录（设置页展示真实路径并支持手动指定）。
- 目录与文件在首次启动时自动创建。

---

## 5. 会话 JSON 模型

会话在内存中的规范表示（同时也是 XML 的映射依据）：

```jsonc
{
  "id": "550e8400-e29b-41d4-a716-446655440000",
  "sandbox": "/Users/x/Documents/XChat/sessions",
  "created_at": "2025-01-15T10:30:00.000Z",
  "updated_at": "2025-01-15T11:45:12.000Z",
  "tool_calls": 3,               // 已发生的工具调用次数（累计）
  "tool_calls_limit": 20,        // 0 = 无限制
  "title": "帮我写一个排序算法",
  "tags": ["编程", "算法"],
  "provider": "deepseek",        // 关联 config.json 中的 provider 名
  "model": "deepseek-reasoner",
  "params": {                    // 会话级模型参数（覆盖全局默认）
    "temperature": 0.7,
    "top_p": null,
    "max_tokens": null,
    "thinking": "auto",          // auto|on|off
    "reasoning_effort": null,    // minimal|low|medium|high
    "reasoning_budget": null
  },
  "thinking_reply_mode": "auto", // auto|reasoning_content|think_tag
  "tools": ["read_file", "write_file", "shell"],  // 启用的工具名
  "messages": [
    { "role": "system", "content": "你是一个专业助手。",
      "usage_cumulative": { "input": 15230, "output": 4120, "cache": 12000, "context": 2680 } },
    { "role": "user", "id": "m1", "content": "帮我用 Dart 写一个快排" },
    { "role": "assistant", "id": "m2", "content": "这是实现：",
      "reasoning": "用户需要……", "reasoning_mode": "reasoning_content",
      "tool_calls": [ { "id": "call_1", "name": "write_file",
                        "arguments": "{\"path\":\"sort.dart\",\"content\":\"...\"}" } ],
      "usage": { "input": 1200, "output": 850, "cache": 300 } },
    { "role": "tool", "id": "m3", "tool_call_id": "call_1", "name": "write_file",
      "content": "OK: wrote sort.dart (123 bytes)", "is_error": false }
  ]
}
```

> `usage_cumulative` 与「单次 usage」分开存放：累计值统一由 `system` 元素承载（§8）。

---

## 6. 会话 XML 格式

### 6.1 规范示例

```xml
<?xml version="1.0" encoding="UTF-8"?>
<chat sandbox="/Users/x/Documents/XChat/sessions">
  <meta>
    <id><![CDATA[550e8400-e29b-41d4-a716-446655440000]]></id>
    <created_at><![CDATA[2025-01-15T10:30:00.000Z]]></created_at>
    <updated_at><![CDATA[2025-01-15T11:45:12.000Z]]></updated_at>
    <tool_calls><![CDATA[3]]></tool_calls>
    <tool_calls_limit><![CDATA[20]]></tool_calls_limit>
    <params>
      <temperature><![CDATA[0.7]]></temperature>
      <top_p><![CDATA[]]></top_p>
      <max_tokens><![CDATA[]]></max_tokens>
      <thinking><![CDATA[auto]]></thinking>
      <reasoning_effort><![CDATA[]]></reasoning_effort>
      <reasoning_budget><![CDATA[]]></reasoning_budget>
    </params>
  </meta>

  <!-- 其余子元素 = 会话 JSON 的对应字段 -->
  <title><![CDATA[帮我写一个排序算法]]></title>
  <tags><![CDATA[编程,算法]]></tags>
  <provider><![CDATA[deepseek]]></provider>
  <model><![CDATA[deepseek-reasoner]]></model>
  <thinking_reply_mode><![CDATA[auto]]></thinking_reply_mode>

  <!-- tools 与 meta 平级，内含多个 tool 元素 -->
  <tools>
    <tool><![CDATA[read_file]]></tool>
    <tool><![CDATA[write_file]]></tool>
    <tool><![CDATA[shell]]></tool>
  </tools>

  <!-- messages 数组 => 顺序排列的消息元素；system 元素承载累计 usage -->
  <system input="15230" output="4120" cache="12000" context="2680">
    <content><![CDATA[你是一个专业助手。]]></content>
  </system>

  <user id="m1">
    <content><![CDATA[帮我用 Dart 写一个快排]]></content>
  </user>

  <assistant id="m2" input="1200" output="850" cache="300">
    <reasoning mode="reasoning_content"><![CDATA[用户需要……]]></reasoning>
    <content><![CDATA[这是实现：]]></content>
    <tool_calls>
      <tool_call id="call_1" name="write_file">
        <arguments><![CDATA[{"path":"sort.dart","content":"..."}]]></arguments>
      </tool_call>
    </tool_calls>
  </assistant>

  <tool id="m3" tool_call_id="call_1" name="write_file" error="false">
    <content><![CDATA[OK: wrote sort.dart (123 bytes)]]></content>
  </tool>
</chat>
```

### 6.2 元素 / 属性表

| 元素                                                    | 父         | 基数 | 属性                               | 说明                                                                              |
| ------------------------------------------------------- | ---------- | ---- | ---------------------------------- | --------------------------------------------------------------------------------- |
| `chat`                                                  | 根         | 1    | `sandbox`                          | 会话文件所在沙箱目录                                                              |
| `meta`                                                  | chat       | 1    | —                                  | 元信息容器                                                                        |
| `meta/id`                                               | meta       | 1    | —                                  | 会话 id（= 文件名）                                                               |
| `meta/created_at`                                       | meta       | 1    | —                                  | ISO-8601 创建时间                                                                 |
| `meta/updated_at`                                       | meta       | 1    | —                                  | ISO-8601 更新时间                                                                 |
| `meta/tool_calls`                                       | meta       | 1    | —                                  | 工具调用次数（累计）                                                              |
| `meta/tool_calls_limit`                                 | meta       | 1    | —                                  | 上限，`0` = 无限制                                                                |
| `meta/params`                                           | meta       | 1    | —                                  | 模型参数容器                                                                      |
| `meta/params/*`                                         | params     | 0/1  | —                                  | 各参数（temperature/top_p/max_tokens/thinking/reasoning_effort/reasoning_budget） |
| `title` `tags` `provider` `model` `thinking_reply_mode` | chat       | 0/1  | —                                  | 对应 JSON 字段                                                                    |
| `tools`                                                 | chat       | 0/1  | —                                  | 工具容器（与 meta 平级）                                                          |
| `tools/tool`                                            | tools      | 0..n | —                                  | 单个启用的工具名（CDATA）                                                         |
| `system`                                                | chat       | 1    | `input` `output` `cache` `context` | 系统消息 + **累计** usage                                                         |
| `user`                                                  | chat       | 0..n | `id`                               | 用户消息                                                                          |
| `assistant`                                             | chat       | 0..n | `id` `input` `output` `cache`      | 助手消息 + **单次** usage                                                         |
| `tool`                                                  | chat       | 0..n | `id` `tool_call_id` `name` `error` | 工具结果                                                                          |
| `content`                                               | 消息       | 1    | —                                  | 正文（CDATA）                                                                     |
| `reasoning`                                             | assistant  | 0/1  | `mode`                             | 思考内容（CDATA），mode 记录来源                                                  |
| `tool_calls`                                            | assistant  | 0/1  | —                                  | 工具调用容器                                                                      |
| `tool_call`                                             | tool_calls | 1..n | `id` `name`                        | 单次调用                                                                          |
| `arguments`                                             | tool_call  | 1    | —                                  | JSON 参数（CDATA）                                                                |

### 6.3 读写规则（CDATA 优先）

- **写**：所有元素文本使用 `XmlBuilder.cdata(text)`，**不做实体转义**；
  属性值（如 `sandbox`、id）为短标识符，保持普通属性。
- **读**：使用 `xml` 包的 `element.text`（自动合并 CDATA 与文本节点）；
  属性用 `getAttribute('input')`。
- 数值属性缺失 ⇒ 视为 `null`（未上报 usage），不写 `0`。
- 未知元素/属性：读取时忽略但**保留**？—— 默认忽略；可选「原样保留扩展元素」开关。
- 写盘原子性：先写 `<id>.xml.tmp` 再 `rename`，避免崩溃损坏会话。

---

## 7. 思考模式兼容与回发

### 7.1 读取（显示）

`llm_api` 的 `ReasoningRouter` 已统一两条通道：

| 来源                                                           | 识别方式         | 产出事件         |
| -------------------------------------------------------------- | ---------------- | ---------------- |
| `reasoning_content`（deepseek/kimi/glm/mimo/qwen/openrouter…） | 响应字段         | `ReasoningDelta` |
| `<think>…</think>`（minimax 等）                               | 正文内联标签解析 | `ReasoningDelta` |

两者都归一化为 `ReasoningDelta`，UI 统一渲染到 `<reasoning>` 块，并记录 `reasoning_mode`。

### 7.2 回发（关键需求）

**规则（已确认）**：只要会话开启了思考（`params.thinking != off`），历史思考就必须回发。
不同模型接受形式不同，回发形态由 `thinking_reply_mode`（会话级）+ 预设默认值决定：

| 模式                | 回发形态                                                                                                               |
| ------------------- | ---------------------------------------------------------------------------------------------------------------------- |
| `reasoning_content` | 在 assistant 消息上附加 `reasoning_content` 字段（字段名取预设，如 `reasoning_content`），并置 `includeInHistory=true` |
| `think_tag`         | 把思考文本包成 `<think>…</think>` 拼接到 `content` 前部；不附加独立字段                                                |
| `auto`              | 由 provider 预设推导（deepseek/kimi/glm/mimo → `reasoning_content`；minimax → `think_tag`）                            |

实现位置：`lib/llm/outbound_adapter.dart`

```
SessionModel(messages) ──► OutboundAdapter ──► llm_api ChatMessage[]
                              │  mode=reasoning_content: 保留 reasoningContent, 置 includeInHistory
                              └─ mode=think_tag: content = "<think>"+reasoning+"</think>\n\n"+content, reasoningContent=null
```

> 说明：`llm_api` 原生仅支持「字段回发」。`think_tag` 回发在**应用层**做转换，
> 无需改动 vendored 包（如需深度定制再直接改包）。

---

## 8. Usage / Token 统计

### 8.1 采集

- 请求侧：`stream_options.include_usage = true`（预设默认开启）。
- 响应侧：`llm_api` 的 `TokenUsage`（`inputTokens/outputTokens/cachedInputTokens`）。
- 映射到本应用口径：`input = prompt_tokens`，`output = completion_tokens`，
  `cache = cached_tokens`（`prompt_tokens_details.cached_tokens` /
  `prompt_cache_hit_tokens`）。当 provider 未上报 cache 时留空（不写 `0`）。

### 8.2 落盘规则

- **单次**（每个 assistant 元素）：
  `input` / `output` / `cache` = 该次 API 调用的用量。
- **累计**（`system` 元素）：
  `input` / `output` / `cache` = 所有 assistant 单次值之和；
  `context` = 最近一次 assistant 的 `input + output`。

```
每次收到 assistant usage：
  assistant.input/output/cache = 本次
  system.input  += 本次.input
  system.output += 本次.output
  system.cache  += 本次.cache
  system.context = 本次.input + 本次.output
  meta.updated_at = now
  → 原子写盘
```

UI：单条消息底部 `UsageBadge`（in/out/cache），会话状态栏累计 + `ContextBar`
（`context / 模型上下文窗口` 占比，窗口值来自预设或手动配置）。

---

## 9. ReAct Agent 设计

### 9.1 单轮（turn）流程

```
user 输入
   │
   ▼ 追加 <user>，原子写盘
构建 messages（system + 历史 + 工具定义，经 OutboundAdapter）
   │
   ▼ 流式请求
模型输出：reasoning / content / tool_calls / usage
   │
   ├─ 写 <assistant>（含 usage、reasoning）
   │
   ├─ 无 tool_calls ──────────────► 完成（FinishReason.stop）
   │
   └─ 有 tool_calls
        ├─ 依次执行工具 → 写 <tool> 结果元素
        ├─ meta.tool_calls += 调用数
        └─ 达到上限？ ──否──► 回到「构建 messages」再请求
                     └─是──► 自动续判（§9.2）
```

### 9.2 工具次数上限与「自动续判」★

- 上限来源：`meta/tool_calls_limit`（`0` = 无限制，不触发续判）。
- 判定：`meta.tool_calls >= tool_calls_limit` 时，**停止本轮工具执行**，进入续判。
- **自动续判 = 自动发送一条对话**：向模型追加一条用户侧消息（模板可配置），
  由模型判断是否继续调用工具：

  > 默认模板（`config.json.continuePrompt`，可编辑）：
  > 「你本会话已累计调用工具 N 次（上限 M）。请判断任务是否已完成：
  > 若已完成，请直接输出最终答复（不要再调用工具）；
  > 若仍需继续，请继续调用工具，我会重置本轮工具预算。」

  续判请求**仍携带工具定义**，因此模型既可直接收敛（无 tool_calls ⇒ 结束），
  也可继续调用工具（有 tool_calls ⇒ 预算重置为 0，按一个新的上限周期继续）。
- 计数策略：续判时把本次限额周期视为「新一轮」，`meta.tool_calls` **保持累计**，
  另用运行时 `budgetRound` 记录当前周期已用次数；达到上限则再次续判。
  （即：上限是「每个续判周期内」的软限制，累计值始终如实记录。）
- 可配置替代方案（设置项，**默认 A**）：
  - 模式 A（**默认**）：模型自判（如上）。
  - 模式 B：弹窗询问用户「继续 / 结束 / 提高上限」。
  - 模式 C：不续判，直接以当前状态结束。

### 9.3 停止 / 取消

- 用户点「停止」→ `CancelToken.cancel()`，结束流式，保留已生成内容，`meta` 正常写盘。
- 网络/协议错误：以 error 事件上抛，assistant 保留错误信息，输入区恢复可用。

### 9.4 消息序列合法性

发送前做 OpenAI 协议规整（借鉴既有经验）：

- `assistant{tool_calls}` 之后必须紧跟对应 `tool` 结果；
- 丢弃孤立 `tool`；
- `assistant{tool_calls}` 且无正文时 `content` 用 `null`/`''` 的兼容处理。

---

## 10. 工具系统

### 10.1 内置工具

| 工具                | 平台   | 说明                                        |
| ------------------- | ------ | ------------------------------------------- |
| `read_file`         | 全平台 | 读取文件（限沙箱）                          |
| `write_file`        | 全平台 | 写入文件（自动建目录）                      |
| `edit_file`         | 全平台 | 搜索替换式编辑                              |
| `list_dir` / `glob` | 全平台 | 目录列举 / 模式匹配                         |
| `shell`             | 桌面   | 执行命令（工作目录 = 沙箱）                 |
| `http_fetch`        | 全平台 | 抓取 URL 文本                               |
| `web_search`        | 全平台 | 多引擎（Bing→DDG→SearXNG），可配 Tavily key |
| `datetime`          | 全平台 | 当前时间                                    |

- 工具集合按会话 `tools` 字段启用；模板可预置。
- 每个工具结果写入独立 `<tool>` 元素（CDATA）。
- 结果过长截断（默认 24k 字符，`llm_api.ToolRegistry.maxResultCharacters`）。

### 10.2 沙箱与安全

- 文件工具仅允许访问会话沙箱目录（`chat@sandbox`）及其子目录，`path_guard` 做
  `realpath` 前缀校验，拦截 `..`、符号链接逃逸。
- `shell` 默认关闭，需在会话/全局显式开启；桌面端可配「确认模式」逐条确认。

---

## 11. 会话功能

### 11.1 创建向导（`session_wizard_page`）

分步：

1. **选择起点**：空白 / 从模板。
2. **模型**：provider + model（下拉，可拉取模型列表）+ 参数（temperature/top_p/max_tokens/thinking）。
3. **系统提示**：输入或从模板带入。
4. **工具与预算**：勾选工具；`tool_calls_limit`（0=无限制）。
5. **存储与标识**：sandbox 目录（默认 `Documents/XChat/sessions`）、标题、标签、
   `thinking_reply_mode`。
6. 生成 `id` → 写入 `<id>.xml` → 进入聊天页。

### 11.2 会话模板（`template_page`）

- 存储：`Documents/XChat/templates/<template-id>.xml`，结构与会话一致（无 messages，
  或含预置 system/few-shot）。
- 字段：名称、说明、provider/model、params、tools、tool_calls_limit、
  system prompt、`thinking_reply_mode`、标签。
- 操作：新建 / 编辑 / 复制 / 删除 / 「用此模板新建会话」。
- 会话创建向导第 1 步即可选用。

### 11.3 编辑工具打开会话

- 设置项 `editor`（命令行模板，如 `code --goto {file}` / `$EDITOR`；`{file}` 占位）。
- 桌面：`Process.start` 调用；未配置则用系统默认程序（`open`/`xdg-open`/`start`）。
- 移动：打开**内置 XML 编辑器**页（等宽字体、基础高亮、保存前做 XML 校验）。
- 保存后回到列表/聊天页自动重新加载。

### 11.4 最近一次 user 消息编辑（= 重发）

- 定位**最后一个 `<user>` 元素**；删除其后的所有元素（assistant/tool…）。
- 将该 user 的 `content` 替换为编辑后的文本。
- 同步修正 `meta.tool_calls`（回退到该点之前的计数）与累计 usage（重算）。
- 确认后立即触发 ReAct 重发。
- UI：消息气泡上的「编辑并重发」按钮 / 长按菜单。

### 11.5 克隆（只复制到第一个 user 元素为止）

- 新建 `id`，`created_at=updated_at=now`，`tool_calls=0`，`context=0`，usage 清零。
- 复制 `system`（含空 system）+ **第一个 `<user>` 元素**（含）为止；
  其后的 assistant/tool 全部丢弃。
- 保留 provider/model/params/tools/limit/tags 等配置。
- 新文件写入同 sandbox；可选立即进入编辑以修改首条 user 后发送。

---

## 12. UI 设计

- **自适应布局**：宽屏（桌面/平板）左「会话列表」+ 右「聊天」；窄屏（手机）
  列表页 ↔ 聊天页路由切换。
- **聊天页**：消息列表（用户右/助手左）、思考块（默认折叠，流式展开）、
  工具调用块（命令 + 结果摘要，可展开全文）、Markdown 正文、usage 角标、
  顶部模型/用量/上下文条、底部输入区（多行、发送/停止、附件可选）。
- **会话列表**：搜索、按标签/项目筛选、按更新时间排序、未读/进行中标记；
  右键/长按菜单：重命名、克隆、编辑重发、导出、在编辑器中打开、删除。
- **设置页**：数据目录（展示 + 打开）、编辑器命令、主题（亮/暗/跟随）、语言、
  全局模型默认参数、续判模式、流式开关、代理（可选）。
- **Provider 管理**：预设一键添加（deepseek/kimi/glm/mimo/minimax/qwen/openai/
  openrouter/ollama…）、自定义 baseUrl/apiKey/headers、测试连接、拉取模型。

---

## 13. Provider 预设

`lib/llm/llm_presets.dart` 封装 `llm_api.LlmPresets` 并补充国内常用端点：

| 预设            | baseUrl                      | 思考读取          | 回发默认          |
| --------------- | ---------------------------- | ----------------- | ----------------- |
| openai          | api.openai.com/v1            | 字段/effort       | reasoning_content |
| deepseek        | api.deepseek.com/v1          | reasoning_content | reasoning_content |
| moonshot(kimi)  | api.moonshot.cn/v1           | reasoning_content | reasoning_content |
| zhipu(glm)      | open.bigmodel.cn/api/paas/v4 | reasoning_content | reasoning_content |
| mimo            | （用户填写，兼容 API）       | reasoning_content | reasoning_content |
| minimax         | （用户填写，兼容 API）       | **`<think>`**     | **think_tag**     |
| qwen            | dashscope compatible-mode    | reasoning_content | reasoning_content |
| openrouter      | openrouter.ai/api/v1         | reasoning         | reasoning_content |
| ollama / 自定义 | 用户填写                     | auto              | auto              |

> mimo / minimax 若无稳定公开 baseUrl，预设提供模板，用户填 key；`reasoning_source`
> 与 `thinking_reply_mode` 在预设中已预调好。

---

## 14. 其他补充功能（建议，供确认）

1. **重新生成**：删除最后一条 assistant（及其后续 tool）后重发。
2. **标题自动生成**：首条 user 触发一次轻量 LLM 调用生成标题（可关，默认截断）。
3. **导入/导出**：单会话 XML 导入导出、批量导出目录、拖拽导入（桌面）。
4. **会话标签/项目**：标签过滤 + 轻量「项目」分组（可选）。
5. **上下文压缩**：超上下文时对旧消息做摘要压缩（复用既有 `Compressor` 思路）。
6. **多语言**：zh/en 切换。
7. **主题**：亮/暗/跟随系统，可自定义主色。
8. **快捷键**（桌面）：`Ctrl/Cmd+N` 新建、`Enter` 发送、`Shift+Enter` 换行、`Esc` 停止。
9. **诊断日志**：可选开关，记录 LLM 请求/响应元数据（不含正文）到 `XChat/logs/`。
10. **用量看板**：按会话/时间统计 token 花费（可选）。
12. **API Key 安全**：优先 `flutter_secure_storage`，回退明文 `config.json`。

---

## 15. 已确认决策

- **Q1｜工具次数上限后的自动续判主体**：**模型自判**（默认）。达到上限即自动追加一条
  用户侧对话，由模型决定继续或收敛。（同时保留设置项可切换为「询问用户/直接结束」。）
- **Q2｜上限语义**：`meta.tool_calls` **始终累计**、如实记录；上限作用于**每个续判周期**
  （续判后预算重置，累计值不变）。
- **Q3｜字段 XML 形态**：`params` 作为 **`meta` 的子元素**（其下再放各参数子元素）；
  `tools` 作为与 `meta` **平级**的元素，内含多个 `<tool>` 元素。
- **Q4｜思考回发**：**只要开启思考就必须回发**历史思考数据（`thinking` 为 off 时回发空）。
  形态 `auto`（按 provider 预设推导）。
- **Q5｜Android 存储**：使用 **App 私有目录**（非 root 可见），不申请共享存储权限。
- **Q6｜状态管理**：`provider`。
- **Q7｜工具范围**：首版包含 `web_search` / `http_fetch`。
- **Q9｜空 `system`**：**保留**空 `<system>` 元素以承载累计 usage。

> Q8（多语言/主题）未决：v1 提供亮/暗主题切换，中英双语延后。

---

## 16. 实现里程碑

1. **M1 骨架**：Flutter 工程 + `packages/llm_api` vendor + 路径/配置仓库 + 主题。
2. **M2 数据层**：Session 模型 + XML 读写（CDATA）+ 单测（round-trip）。
3. **M3 LLM 层**：预设 + provider 工厂 + 流式对话打通 + usage 采集 + 思考显示/回发。
4. **M4 Agent**：ReAct 循环 + 工具注册 + 工具次数上限 + 自动续判 + 单测。
5. **M5 UI**：聊天页 + 会话列表 + 消息/思考/工具/用量组件。
6. **M6 会话功能**：创建向导、模板、克隆、编辑重发、外部/内置编辑器。
7. **M7 收尾**：设置页、Provider 管理、多平台编译验证（先 Android）。

---

## 17. models.dev 集成（模型参数与一键更新）

模型/提供商元数据（端点、模型清单、上下文窗口、输出上限、思考参数、工具支持）来自开源
数据库 [models.dev](https://models.dev)，避免内置默认值随上游漂移。

- **数据源**：`https://models.dev/api.json?type=all`（含全部模型类型）；
  解析为 `ModelsDevCatalog`（`lib/models/models_dev.dart`）。
- **快照与回退链**（`ModelsDevRepository.loadOrRefresh`）：
  1. 实时拉取 models.dev 并缓存为 `models_dev.json`；
  2. 网络失败 → 上次缓存的 `models_dev.json`；
  3. 无缓存 → **内置预置快照** `assets/models_dev/models_dev.json`（打包随应用分发）。
  三者都失败才报错。内置快照是 models.dev 数据的裁剪版：仅保留带 OpenAI 兼容端点
  （或内置预设）的提供商，剔除专用/已弃用模型，每提供商最多保留发布最新 50 个模型、
  描述截断 200 字符，只保留应用实际读取的字段（约 1.2MB）。联网成功后自动恢复完整目录。
- **一键更新**（模型服务页 AppBar ⟳）：对每个已配置服务按 **ID → 端点 host → 内置预设别名**
  匹配目录条目，然后：
  - 模型清单：保留用户已有条目与顺序（未知 id 视为自定义部署，保留）；剔除目录中标记
    `deprecated` / 专用类型（如 `decision`）的条目；按发布日期从新到旧追加支持工具调用的新模型。
  - 模型参数：为每个模型写入 `model_specs`（上下文窗口、最大输出、reasoning/tool 能力），
    上下文条按 **当前模型** 的窗口计算（`ProviderConfig.contextWindowFor`），
    服务级 `context_window` 取所有模型的最大值。
  - 端点/名称：仅当为空、同 host 或仍为内置默认值时改写（Base URL 会归一化补 `/v1`）；
    自定义镜像网关、API Key、Headers、预设与思考回发设置永不覆盖。
  - 思考参数：由 `reasoning_options`（`budget_tokens`/`effort`/`toggle`）与 `interleaved`
    推导 `reasoning_style` / `reasoning_source`；仅对 `custom` 服务补全未设置项，
    预设服务的调优值保持不变。
- **编辑页「从 models.dev 填充」**：按同一匹配规则整表填充（含名称/端点/思考参数），
  用户核对后保存；未匹配时提示先填写正确的 ID 或 Base URL。
- **添加向导（模型服务页 ➕ → 从 models.dev 添加）**：
  1. 搜索并挑选提供商（展示端点 host、协议、模型数量；非 OpenAI 兼容协议仅提供模型信息，
     端点不自动填充）；
  2. 勾选模型（默认预选最新 10 个支持工具调用的模型，支持搜索/全选/清空，展示上下文、
     输出上限与思考/工具能力，已剔除 deprecated 与专用类型）；
  3. 生成预填服务（ID 自动去重；命中内置预设则沿用其预设与思考回发方式；模型参数、
     推导的思考参数、归一化端点均已填好）并转到编辑页，补填 API Key 后保存。
