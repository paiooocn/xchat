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
├── scripts/             # 页面解析脚本（<id>.json，隐藏 WebView 用，见 §19）
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
| `web_search`        | 全平台 | 多引擎（隐藏 WebView 渲染 SERP 后按脚本解析，按配置顺序回退） |
| `webview_fetch`     | 全平台 | 隐藏 WebView 加载 URL 返回渲染内容（outline/html/text，见 §19） |
| `webview_extract`   | 全平台 | 按解析脚本提取结构化结果（见 §19）           |
| `webview_script_mount` | 全平台 | 挂载/更新页面解析脚本（持久化，见 §19）    |
| `webview_script_list` | 全平台 | 列出已挂载的页面解析脚本                    |
| `webview_script_unmount` | 全平台 | 卸载页面解析脚本                        |
| `attach_image`      | 全平台 | 把沙箱内图片附加到对话，模型下一轮即可看到   |
| `datetime`          | 全平台 | 当前时间                                    |

- 工具集合按会话 `tools` 字段启用；模板可预置。
- 每个工具结果写入独立 `<tool>` 元素（CDATA）。
- 结果过长截断（默认 24k 字符，`llm_api.ToolRegistry.maxResultCharacters`）。

### 10.1.1 Agent 自产图片（`attach_image`）

Agent 自己没有视觉输入通道，图片只能由工具产出：先用 `shell` 生成图片
（如 `chromium --headless --screenshot=shot.png --window-size=1280,800 <url>`），
再调用 `attach_image` 登记。链路与用户手选图完全同构：

```
shell 产出 PNG → attach_image 校验（沙箱/格式/体积）→ 落盘 attachments/<id>-<n>.png
              → 挂在该 <tool> 消息上 → 出站编码为紧随其后的 user 图片消息
```

- **为什么多一跳**：OpenAI 兼容协议下 `role: tool` 的 `content` 只能是字符串，
  图片挂不上去，必须紧跟一条只含 `image_url` 的 user 消息——这是所有兼容端点
  唯一一致的编码方式。因此 `<tool>` 消息仍保持纯文本，附件单独成条。
- **体积闸门**：`AppConfig.maxAttachmentBytes`（设置页可配，默认 5MB，0 = 不限制）
  同时约束用户选图与 `attach_image`。图片以 base64 内联进请求体（约 +33%），
  这是**传输体积**闸门，不是 token 预算；上下文与计费仍以服务端 `usage` 为准。
- 校验逻辑集中在 `agent/tools/image_attach.dart`，工具与引擎共用同一份判定，
  避免「工具说成功、实际没图」。

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

### 11.6 多会话并行（切换不中断）

- 每个会话的 `SessionController`（及其驱动的 Agent 轮次）由 `AppState` 按
  会话 id 持有（`controllerFor`），**不再随聊天面板的切换而被销毁**：
  切换到另一个会话时，原会话的流式对话继续在后台运行、落盘。
- 面板只负责监听控制器并渲染；会话被删除时其控制器才随之释放。
- `AppState.runningSessionIds` 汇总各控制器的运行状态（仅在集合变化时
  通知，避免流式 delta 触发全量重建），边栏据此把进行中会话的图标替换为
  旋转圈。

### 11.7 打开工作目录

- 会话「更多操作」菜单新增「打开工作目录」：用系统文件管理器
  （macOS `open` / Windows `explorer` / Linux `xdg-open`）打开该会话的
  sandbox 目录，便于直接查看 Agent 产出的文件。

---

## 12. UI 设计

- **自适应布局**：宽屏（桌面/平板）左「会话列表」+ 右「聊天」；窄屏（手机）
  列表页 ↔ 聊天页路由切换。
- **聊天页**：消息列表（用户右/助手左）、思考块（默认折叠，流式展开）、
  工具调用块（命令 + 结果摘要，可展开全文）、Markdown 正文、usage 角标、
  顶部模型/用量/上下文条、底部输入区（多行、发送/停止、附件可选）。
- **会话列表**：搜索、按标签/项目筛选、按更新时间排序；进行中的会话以
  **旋转圈图标**代替会话图标（多会话并行时一眼可见）；项目行尾提供「+」
  图标按钮直接在项目内新建会话（位于「更多操作」菜单左侧）；
  右键/长按菜单：重命名、克隆、编辑重发、导出、在编辑器中打开、
  打开工作目录、删除。
- **设置页**：数据目录（展示 + 打开）、编辑器命令、主题（亮/暗/跟随）、语言、
  全局模型默认参数、续判模式、流式开关、代理（可选）。
- **Provider 管理**：预设一键添加（deepseek/kimi/glm/mimo/minimax/qwen/openai/
  openrouter/ollama…）、自定义 baseUrl/apiKey/headers、测试连接、拉取模型。
- **图片附件**：落盘在 `<sandbox>/attachments/`，XML 只存相对路径；发送时
  base64 内联，文本 part 置于图片 part **之后**。格式：png / jpg / webp / gif / bmp。

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

---

## 18. v0.2.0 变更记录

- **项目行「+」新建会话**：边栏项目分组内原来的文字项「在项目中新建会话」上移到
  项目行尾，改为「+」图标按钮，位于「更多操作」菜单图标左侧（折叠状态下也能直接新建）。
- **多会话并行**：`SessionController` 改由 `AppState` 按会话 id 持有，切换会话不再
  销毁/停止原会话的对话；进行中的会话在边栏以旋转圈图标代替原会话图标
  （见 §11.6）。
- **打开工作目录**：会话「更多操作」菜单新增「打开工作目录」，用系统文件管理器
  打开该会话的 sandbox（见 §11.7）。

---

## 19. 隐藏 WebView 搜索与脚本提取

### 19.1 动机

直接 HTTP 请求搜索引擎会被反爬（TLS/JA3 指纹、IP 信誉、cloaked SEO-spam），
因此搜索只保留隐藏 WebView 一种请求方式（原「引擎自带」HTTP/API 模式已移除），
本地 headless Chromium（`--dump-dom`）也可能被检测（`navigator.webdriver`）。
本方案在**真实浏览器环境**（隐藏 WebView）中加载页面，再用页面内 JS 解析结果。

跨平台由 `webview_all` 提供：Android/iOS/macOS/Windows 用系统 WebView，
**Linux 用 WebKitGTK 4.1**（构建前需 `apt install libwebkit2gtk-4.1-dev`）。
离屏会话 `OffscreenWebViewSession` 无需可见 widget。

### 19.2 三层执行

| 层 | 机制 | 特点 |
| --- | --- | --- |
| L1 | `BrowserSession.get`（HTTP 模拟） | 快，易被反爬（仅 `http_fetch` 等使用） |
| L2 | headless Chromium（`render`） | 中，可能被检测（同上） |
| L3 | **隐藏 WebView（`WebViewExtractor`）** | 最真实，绕过大部分反爬 |

**搜索只走 L3**：`web_search` 与手动搜索页都经 `BuiltinTools.search` →
`_searchOne`，在隐藏 WebView 中加载引擎的 SERP URL 再解析；引擎顺序即回退策略
（前一个引擎被拦/改版就顺延到下一个）。解析脚本来源优先级：内联 `extractScript` >
`ScriptRegistry` 命中（内置 baidu/bing/duckduckgo/google/sogou）> 引擎 CSS 选择器动态生成。

**多页聚合**：单页 SERP 通常只有 ~10 条，且首页含赞助/遮蔽结果。搜索会按
「下一页」选择器（脚本 `next_selector` 优先，其次引擎配置 `next_selector`）继续加载
后续页，**跨页按 URL 去重后合并成一个结果列表**，再统一走相关性与垃圾过滤，最后按
`max_results` 截断。页数取值优先级：手动搜索页「聚合页数」/`web_search` 的 `pages`
参数 > 引擎配置 `pages`（1–10，默认 1）。缺少下一页链接、或某一页没有新增结果即提前
结束（`PagedExtraction.pagesFetched`）；没有 `next_selector` 时退化为单页。实际页数
少于请求页数时，结果里会附一条诊断（`WebSearchOutcome.notes`），例如
「翻页提前结束：请求 3 页，实际解析 1 页」。

### 19.3 脚本注册表

`ScriptRegistry` 合并两源并按 URL 匹配选脚本：

1. 内置 `assets/scripts/*.json`（只读，google/bing/duckduckgo/baidu/sogou）；
2. `<root>/scripts/<id>.json`（agent/用户自建，可写；同 id 覆盖内置）。

匹配优先级：`url_pattern` 正则 > 精确 host > host 后缀；同分比较 `priority`。

### 19.4 存储格式

```
<root>/
  scripts/
    <id>.json            # 每脚本一个文件，跨会话复用
```

```jsonc
{
  "id": "example",
  "name": "Example SERP",
  "created_by": "agent",              // builtin | user | agent
  "origin_url": "https://example.com/search?q=test",
  "match": { "hosts": ["example.com"], "path_prefix": "/search", "url_pattern": "" },
  "ready_selector": "li.result",
  "next_selector": "a.sb_pagN",
  "priority": 10,
  "enabled": true,
  "created_at": "…", "updated_at": "…",
  "body": "(function(){ … return JSON.stringify([{title,url,snippet}]); })()"
}
```

**复用靠 URL 模式匹配**（非「完全相同 URL」）：agent 分析过
`…/search?q=test` 后，同站点不同 query 也命中；需精确锁定时用 `url_pattern`。
**一次挂载，`web_search` 与 `webview_extract` 同时生效，重启保留**。

### 19.5 Agent 工具

| 工具 | 审批 | 用途 |
| --- | --- | --- |
| `webview_fetch` | 0 | 加载 URL 返回渲染内容（`mode=outline/html/text`） |
| `webview_extract` | 0 | 按脚本提取（验证脚本） |
| `webview_script_mount` | 1 | 挂载脚本（持久化到 `<root>/scripts/`） |
| `webview_script_list` | 0 | 列出脚本 |
| `webview_script_unmount` | 1 | 卸载脚本（内置仅禁用） |

### 19.6 Agent 闭环

```
webview_fetch(outline) → webview_fetch(html, selector) → 写脚本
  → webview_extract(验证) → webview_script_mount(持久化)
  → 后续 web_search / webview_extract 自动复用
```

### 19.7 关键实现

- `WebViewExtractor`：进程内单例，懒加载离屏会话，单飞锁串行执行，30s 超时；
  不可用时 `available=false`，调用方回退 L1/L2。
- 验证码检测复用 `BrowserSession.looksBlocked`（命中抛 `WebViewBlockedException`）。
- 脚本返回 JSON 字符串，Dart 侧 `WebViewExtractor.decodeResults` 解码后走现有
  `_usable()` 过滤链（去重/相关性/跳转解包）。
- 代理：WebKitGTK 走系统代理；`ProxyConfig` 通过环境变量注入。
- 失败落盘：WebView 提取为空时，页面 HTML 落盘到 `<root>/logs/webview/last.html`，供离线分析结构。
- 脚本求值用 `runJavaScriptReturningResult`（**不是** `callAsyncJavaScript`：后者会把 IIFE 再包一层函数，丢弃其返回值 → `null`）。
- 多页聚合：`WebViewExtractor.evaluatePaged` 逐页解析并跨页去重合并；`web_search`
  与手动搜索页共用 `BuiltinTools.search` → `_searchOne` 这一条路径。
- **翻页是「验证过的」而不是「假定的」**：依次尝试三种触发方式 —— ①鼠标事件序列
  （`mousedown/mouseup/click`）让站点自己的翻页 JS 跑起来（Bing 用它在 JS 里补出
  `cvid`/`rdr`/`FORM=PERE` 等上下文并改写分页 URL）；②页面内 `location.assign(href)`；
  ③Dart 侧 `loadRequest(href)`；每次触发后都要等到**解析结果集真的变化**（首条 URL 或
  条数不同）才算一页。原因：SERP 分页是上下文相关的，把 Bing 分页链接里的
  `…&first=11&FORM=PORE` 当新导航直接加载会被当作「重新搜第 1 页」；而旧 DOM 同样满足
  `ready_selector`，所以「选择器命中」不能证明页面已前进。未前进即停止并在
  `PagedExtraction.note` 中给出原因（URL 是否变化、结果集是否相同），不再静默少返回。
- **一次「白跑」是正常的，必须重试而不是等待**（2026-10 实测，WebKitGTK 2.52 +
  Chromium 149 对照）：会话里**第一次**点击分页链接会被引擎回以第 1 页（Bing 45s 以上
  都不变，所以「等久一点」无效），但这次落地会重写 pager 的 `href`（Bing 追加一个新的
  `FPIG`），**再点一次那个新链接就真的前进**（`sb_pagS` 1→2→3，首条结果变化）。
  因此 `_advance` 最多跑 `_advanceRounds`（3）轮：某轮「已导航但结果集未变」不再直接
  判死，而是从重写后的 DOM 重新取 `href` 再触发一轮；一轮里一旦导航成功就 break，
  不再用另外两种触发方式重复请求同一个 URL。超过上限才报
  「已导航到 …，但结果集与上一页相同（引擎忽略了分页参数，已重试 3 轮）」。
- 翻页诊断落盘：页数未达请求值时把 query/URL/`next_selector`/每页条数与新增数追加到
  `<logs>/webview/paging.log`（`PagedExtraction.trace`），供事后判断是「引擎拒绝翻页」
  还是「我们的触发失败」。
- 截图/落盘用同一 UA：`captureHtml` 也设置桌面 Chrome UA —— 否则引擎返回的是另一个
  （lite）变体，dump 出来的分页链接形态与搜索时看到的并不一致，调试时会被带偏。

### 19.8 手动搜索页（GUI 验证台）

`SearchPage`（首页 AppBar「手动搜索」图标）是 `web_search` 的 GUI 验证台：

- 选择搜索引擎（含 disabled 引擎，便于调试）、输入搜索内容（结果不做条数限制）；
- 复用 `BuiltinTools.search(..., diagnose: true)`（与 `web_search` 工具**同一实现**），
  列表展示标题/URL/摘要；解析不到结果时额外落盘 SERP HTML 便于修脚本；
- 单击列表项 → 系统浏览器打开（`openUrl`：`xdg-open` / `open` / `start`）；
- 列表项右侧「解析」按钮 → 隐藏 WebView 加载该 URL 并展示渲染文本
  （与 `webview_fetch` 同一执行器 `WebViewExtractor`）；
- 请求方式只有一种：**隐藏 WebView**（唯一搜索通道，`BuiltinTools.search`）。
- 「相关性过滤」开关：关闭后只做去重/截断（`_dedupe`），展示**引擎直出**结果，
  便于对比过滤前后差异（`WebSearchOutcome.filtered`）；
- 「完全原始」开关：不去重、不筛选、不截断，展示脚本解析出的**全部条目**
  （`raw: true`），用于核对引擎原始结果条数；
- 「聚合页数」：聚合成一个列表的 SERP 页数（留空 = 引擎配置 `pages`），
  多页结果跨页按 URL 去重后合并再展示；
- 「翻页诊断」：实际解析页数少于请求页数时，结果上方显示原因
  （`WebSearchOutcome.notes`：缺 `next_selector` / 触发后页面未变化 / 已导航但结果集
  与上一页相同（该情况会先重试 3 轮，见 §19.7）），同一份 trace 追加到
  `<logs>/webview/paging.log`。
