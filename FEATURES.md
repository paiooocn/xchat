# XChat 功能点全清单（供其他框架/语言重写参考）

> 基于 Flutter 实现的跨平台 **LLM Agent GUI**（Android / iOS / macOS / Windows / Linux）。
> 本文按「数据层 → LLM 层 → Agent 层 → 会话功能 → 搜索/WebView → UI → 设置 → 平台差异」梳理全部功能点，
> 与框架无关，可直接作为重写的需求规格。设计动机与决策见 `DESIGN.md`。

---

## 0. 总览

| 维度 | 内容 |
| --- | --- |
| 形态 | 原生 GUI（非 WebView 壳）的 LLM Agent 客户端 |
| 协议 | OpenAI 兼容 API（另含 Anthropic / Gemini 适配层，见 §4） |
| Agent | ReAct 循环（模型 → 工具 → 模型…），带工具次数预算与自动续判 |
| 持久化 | 本地文件：会话为 XML（CDATA），配置为 JSON，目录 `Documents/XChat/` |
| 特色 | 思考链双模式显示/回发、Token 统计、沙箱工具、隐藏 WebView 搜索与脚本提取、多会话并行 |

---

## 1. 数据层 / 持久化

### 1.1 目录布局

```
Documents/XChat/                  # 数据根（AppPaths）
  config.json                     # 全局配置（见 §8）
  index.json                      # 会话/项目目录索引（见 §1.5）
  models_dev.json                 # models.dev 目录缓存
  sessions/                       # 默认沙箱：<uuid>.xml
  projects/<id>.xml               # 项目定义
  projects/<id>/                  # 项目默认工作目录（项目内会话的沙箱）
  templates/                      # 会话模板 <id>.xml
  scripts/                        # 页面解析脚本 <id>.json
  attachments/                    # （会话级：<sandbox>/attachments/）
  logs/                           # 诊断日志；logs/webview/（SERP 落盘、paging.log）
```

- 首次启动自动建目录；Android 用 App 私有目录（可申请外部存储迁移到
  `{外部存储}/com.yimo.xchat/data`，未授权回退私有目录；设置页可查看/迁移）。
- 所有写盘**原子性**：先写 `.tmp` 再 rename。

### 1.2 会话 XML 格式（核心契约）

- 根元素 `chat`，属性 `sandbox` = 会话文件所在目录；文件名 = 会话 UUID。
- 文本一律 **CDATA**，不做实体转义；属性值（id、usage 数值等）用普通属性。
- 结构（详见 DESIGN.md §6）：

```xml
<chat sandbox=".../sessions">
  <meta>
    <id/><created_at/><updated_at/>
    <tool_calls/><tool_calls_limit/>
    <params><temperature/><top_p/><max_tokens/><thinking/><reasoning_effort/><reasoning_budget/></params>
  </meta>
  <title/><tags/>              <!-- tags 逗号分隔 -->
  <provider/><model/><thinking_reply_mode/>
  <tools><tool/><tool/>…</tools>
  <system input="…" output="…" cache="…" context="…">   <!-- 累计 usage -->
    <content/>
  </system>
  <user id="…"><content/><attachments>…</attachments></user>
  <assistant id="…" input="…" output="…" cache="…">      <!-- 单次 usage -->
    <reasoning mode="reasoning_content|think_tag"><![CDATA[…]]></reasoning>
    <content/>
    <tool_calls><tool_call id="…" name="…"><arguments/></tool_call></tool_calls>
  </assistant>
  <tool id="…" tool_call_id="…" name="…" error="true|false"><content/></tool>
</chat>
```

- 读写规则：数值属性缺失视为 `null`（不写 0）；未知元素忽略；空 `<system>` 保留（承载累计 usage）。
- 会话 JSON 模型字段：`id / sandbox / created_at / updated_at / tool_calls / tool_calls_limit /
  title / tags / provider / model / params / thinking_reply_mode / tools / messages[]`；
  消息字段：`role(system|user|assistant|tool) / id / content / reasoning(+mode) /
  tool_calls[{id,name,arguments}] / tool_call_id / name / is_error / usage / attachments`。

### 1.3 模板 XML / 项目 XML

- 模板：与会话同构但无 messages（或含预置 system/few-shot），含名称、说明、provider/model、
  params、tools、tool_calls_limit、system prompt、thinking_reply_mode、标签。
- 项目：`id / name / description / sandbox / created_at / updated_at / provider / model / system_prompt / archived_at`。

### 1.4 Token usage 口径

- `TokenUsage{ input, output, cache }`；`context = 最近一次 input+output`。
- **单次**写在 `assistant` 属性；**累计**写在 `system` 属性（input/output/cache 之和 + context）。
- 每次收到 usage：累加 system、更新 context、`updated_at=now`、原子写盘。
- 未上报的项留空（null），不写 0。

### 1.5 目录索引 index.json

- 四桶目录：`sessions / projects / archivedSessions / archivedProjects`（含标题、标签、
  时间、provider/model 等摘要），供列表/筛选/归档查询，避免逐个解析 XML。
- 每次加载与磁盘目录比对（按 id 集合），文件变动则透明重建；损坏文件跳过不阻塞。

### 1.6 会话归档

- 会话与项目均支持**归档**（`archived_at` 时间戳），归档后从活动列表移入归档页，可恢复/彻底删除。

---

## 2. 核心数据模型

| 模型 | 字段 / 说明 |
| --- | --- |
| `Session` | 见 §1.2；含 clone 系列的切片逻辑（到 system / 到首个 user / 到首轮结束 / 全量） |
| `SessionMessage` | role/id/content/reasoning(+mode)/toolCalls/tool_call_id/name/is_error/usage/attachments |
| `SessionParams` | temperature / top_p / max_tokens / thinking(auto\|on\|off) / reasoning_effort / reasoning_budget |
| `ProviderConfig` | id/name/preset/baseUrl/apiKey/headers/reasoning_source/reasoning_style/ thinking_reply_mode/contextWindow/max_output_tokens/use_max_completion_tokens/models[]/modelSpecs{} |
| `ModelSpec` | 每模型：contextWindow / maxOutputTokens / reasoning / toolCall / status |
| `SessionTemplate` | 模板字段（§1.3） |
| `Project` | 项目字段（§1.3） |
| `AppConfig` | 全局配置（§8） |
| `MessageAttachment` | mimeType/name/path（沙箱相对）或 base64 data；支持 png/jpg/jpeg/webp/gif/bmp |
| `SearchEngineConfig` | id/name/enabled/urlTemplate({query} 占位)/ready_selector/item_selector/ title_selector/link_selector/snippet_selector/next_selector/pages(1–10)/priority |
| `ProxyConfig` | http_proxy / https_proxy / no_proxy（可仅对 http_fetch 生效） |
| `ExtractScript` | 页面解析脚本（§6.3）+ `UrlMatcher`（url_pattern 正则 > 精确 host > host 后缀，同分比 priority） |
| `CatalogIndex` | index.json 的四桶目录（§1.5） |

---

## 3. LLM 层

### 3.1 客户端能力（vendor 包 `llm_api`）

- OpenAI 兼容**流式**（SSE）对话 + 工具调用（function calling）+ usage 采集
  （`stream_options.include_usage`）。
- 三 provider 适配：`openai_compatible` / `anthropic` / `gemini`；预设（presets）含
  openai / deepseek / moonshot / zhipu / mimo / minimax / qwen / openrouter / ollama /
  groq / mistral / siliconflow / together / xai / gemini / anthropic / local。
- `ChatStreamAggregator`：把流式 delta 聚合成完整消息（含 tool_calls 增量、
  重复片段只补缺不重复追加）。
- 思考归一化 `ReasoningRouter`：`reasoning_content` 字段与正文内联 `<think>…</think>`
  两种来源统一产出 `ReasoningDelta`；`ThinkTagParser` 负责内联标签解析/剥离。
- `CancelToken` 取消；`ToolRegistry`（含结果截断上限，默认 24k 字符）；
  错误模型（网络/协议/限流）；MockTransport 测试桩。
- 请求规整：assistant{tool_calls} 后必须紧跟对应 tool 结果；丢弃孤立 tool。

### 3.2 思考回发（OutboundAdapter）

- 规则：会话开启思考（`thinking != off`）即回发历史思考；形态由
  `thinking_reply_mode`（auto|reasoning_content|think_tag）+ provider 预设决定：
  - `reasoning_content`：assistant 消息带 `reasoning_content` 字段回传；
  - `think_tag`：思考包成 `<think>…</think>` 拼在 content 前；
  - `auto`：按预设推导（deepseek/kimi/glm/mimo→字段；minimax→think_tag）。
- `thinking=off` 时回发空。

### 3.3 LLM 工厂与辅助

- `createProvider(ProviderConfig)` → llm_api provider（含 baseUrl 归一化补 `/v1`、
  自定义 headers、代理注入）。
- **会话自动命名**：取首轮对话（首条 user + 其后 assistant，截 2000 字）让模型生成
  ≤20 字中文标题（temperature 0.3，maxTokens 64），清洗装饰符后截 30 字。两种触发：
  按首条 user 命名 / 按当前内容命名。
- **会话压缩**：把 user/assistant 转写稿 + 用户选择的压缩提示词 + 固定框架指令发给模型，
  流式产出 Markdown 上下文摘要；落盘为「摘要 handoff + 后续对话」的新会话形态
  （摘要作为此前全部上下文）。内置 3 条预置压缩提示词（可维护、可自定义）。
- **系统提示词生成器**（模板向导用）：按场景类别（商业/办公/生活/编程/旅游）+ 用途描述
  流式生成 system prompt；支持按修改指令**迭代改写**（refine）。

---

## 4. Agent 引擎

### 4.1 ReAct 主循环

1. 发送（追加 user 或复用历史编辑重发）→ 构建 messages（system + 历史 + 工具定义，经 OutboundAdapter）。
2. 流式请求，事件流：`RoundStarted / ReasoningDelta / ContentDelta / ToolCallStarted /
   ToolCallArgumentsDelta / ToolResult / AssistantCompleted / ContinueDecision /
   UsageUpdated / Error / Finished / Stopped`。
3. 输出含 tool_calls → 执行工具（带审批）→ 写 `<tool>` 结果 → 回到 2；
   无 tool_calls → 结束。
- 每轮结束原子写盘；错误上抛事件，保留已生成内容。
- **停止**：CancelToken 取消，保留内容正常落盘；挂起的审批请求自动按「拒绝」丢弃。

### 4.2 工具次数预算与自动续判 ★

- 会话级 `tool_calls_limit`（0=不限）；`meta.tool_calls` 始终**累计**如实记录。
- 上限作用于**每个续判周期**（运行时 budgetRound 计数）。
- 达到上限 → 自动追加一条用户侧消息（模板可配，`{n}` 累计次数 / `{limit}` 本轮上限占位），
  请求**仍携带工具定义**，由模型自判：直接答复（结束）或继续调工具（预算重置新一轮）。
- 续判模式三选一（设置项）：模型自判（默认）/ 询问用户 / 直接结束。
- 另有 `maxToolCallsPerTurn`（单轮硬上限，0=由预算推导）。

### 4.3 执行模式与审批 ★

- 会话执行模式 `AgentMode`：**普通(1) / 自动(2) / 托管(3)**（会话上持久化，可切换）。
- 每个工具配置审批等级 0..3；需要审批 ⇔ `mode值 <= 等级`：
  0=从不审批；1=仅普通模式审批；2=普通/自动审批；3=总是审批。
- 默认等级：只读/网络类 0；webview 脚本挂载/卸载 1；write_file/edit_file 2；shell 3。
- **全局审批中心**（跨会话队列）：多会话并行时审批请求不随面板切换丢失；
  列出所有挂起请求（会话标题/工具/参数/原因），允许/拒绝；会话停止或删除时批量丢弃。
- 审批弹窗展示「为何要审批」（如 shell 命中哪级名单），可附带一键将命令加入名单放宽。

### 4.4 图片附件链路

- 用户选图 / Agent `attach_image` 共用同一校验（格式 png/jpg/jpeg/webp/gif/bmp +
  体积上限 `maxAttachmentBytes`，默认 5MB，0=不限，硬顶 64MB）。
- 落盘 `<sandbox>/attachments/<id>-<n>.<ext>`（复制而非引用，保证会话自包含）。
- 出站编码：base64 内联 image_url，**紧跟一条只含图片的 user 消息**（role:tool 的
  content 只能是字符串）；文本 part 放图片 part 之后。
- Agent 侧：工具结果中检测 `attach_image` / `read_file` 读图，二次校验后挂到该 tool 消息。

---

## 5. 工具系统（Agent 可调用）

### 5.1 内置工具清单

| 工具 | 参数 | 说明 |
| --- | --- | --- |
| `read_file` | path, max_chars | 读文件（限沙箱；图片文件返回图像） |
| `write_file` | path, content | 覆盖写，自动建父目录 |
| `edit_file` | path, old_string, new_string, replace_all | 精确字符串替换 |
| `list_dir` | path | 列目录 |
| `glob` | pattern, max_results | glob 匹配文件 |
| `shell` | command, timeout_seconds | 执行命令，工作目录=沙箱（桌面端；需启用+审批） |
| `attach_image` | path | 沙箱内图片附加到对话（下一轮可见） |
| `http_fetch` | url, max_chars | GET 抓取 URL，HTML 转纯文本（可走代理） |
| `web_search` | query, max_results, pages | 隐藏 WebView 搜索（§6），多引擎回退、多页聚合 |
| `datetime` | — | 本地 + UTC 当前时间 |
| `webview_fetch` | url, mode(outline\|html\|text), selector, wait_selector, max_chars | 隐藏 WebView 渲染页面取内容 |
| `webview_extract` | url, script_id 或 inline script, max_results | 按脚本提取结构化结果（验证脚本） |
| `webview_script_mount` | script(JSON) | 挂载/更新解析脚本（持久化，需审批） |
| `webview_script_list` | — | 列出脚本 |
| `webview_script_unmount` | script_id | 卸载（内置脚本仅禁用，需审批） |

- 工具按会话 `tools` 字段启用；结果过长截断（默认 24k 字符）。
- 每个工具结果写独立 `<tool>` 元素。

### 5.2 沙箱安全

- 文件工具仅可访问会话 sandbox 及子目录：`PathGuard` 做 realpath 前缀校验，
  拦截 `..` 与符号链接逃逸（抛 `SandboxViolation`）。
- `shell` 默认关闭（需显式开启）；见 §5.3 命令分级。

### 5.3 Shell 命令策略（正则名单）★

- 三条名单（每条为不区分大小写的**正则**，对整条命令匹配；非法正则退化为子串匹配）：
  - **F级（deny）**：永不执行（如 sudo/su/mkfs/fdisk/shutdown/dd/`rm -rf /`/fork bomb）；
  - **2级**：高危副作用（rm/mv/cp/kill/chmod/tar/unzip…）→ 审批等级 2；
  - **1级**：日常副作用（git/npm/pip/cargo/make/docker/curl…）→ 审批等级 1；
  - 未命中 → 工具基础等级（shell 固定 3）。
- 优先级 F > 2 > 1 > base；**任一名单为空 ⇒ shell 工具整体禁用**。
- 名单可在「工具管理」页编辑，支持一键应用默认名单、导入/导出 JSON。

---

## 6. 隐藏 WebView 搜索与脚本提取

### 6.1 动机与通道

- 直连搜索引擎被反爬（TLS 指纹等），headless Chromium 也被检测，故搜索**只走隐藏
  WebView**（真实浏览器环境，离屏会话 OffscreenWebViewSession）。
- 跨平台：Android/iOS/macOS/Windows 系统 WebView；Linux 用 WebKitGTK 4.1
  （构建依赖 `libwebkit2gtk-4.1-dev`）。
- 三层取数：L1 HTTP 模拟（http_fetch 用）→ L2 headless Chromium → L3 隐藏 WebView
  （搜索专用）；L3 不可用时回退。

### 6.2 搜索流程

- 引擎列表按顺序回退（配置顺序即回退策略），支持启用/禁用（含调试用禁用引擎）。
- 流程：加载引擎 SERP URL（URL 模板 `{query}` 占位）→ 等 `ready_selector` 出现 →
  按脚本/选择器解析条目（title/url/snippet）→ 过滤链：跳转链接解包、去重、相关性过滤
  （SearchFilter）、按 max_results 截断。
- **多页聚合**：按 `next_selector` 翻页，跨页 URL 去重合并；页数取值
  （参数 > 引擎配置，1–10）；缺下一页或某页无新增即提前结束，结果附诊断 notes。
- **翻页验证式触发**（非假定）：①鼠标事件序列（mousedown/mouseup/click，让站点 JS 补
  上下文）→ ②页内 `location.assign(href)` → ③Dart 侧 loadRequest；每轮必须等**结果集
  真变化**才算前进；「白跑一轮」属正常（引擎会重写 pager href），最多重试 3 轮后报因。
- 翻页诊断追加到 `logs/webview/paging.log`；提取为空时页面 HTML 落盘
  `logs/webview/last.html`；dump 用与搜索相同的桌面 Chrome UA。
- 脚本求值须用 `runJavaScriptReturningResult`（不能用 callAsyncJavaScript，会丢 IIFE 返回值）。

### 6.3 解析脚本注册表（ScriptRegistry）

- 两源合并按 URL 匹配选脚本：内置 `assets/scripts/*.json`（google/bing/duckduckgo/
  baidu/sogou）+ 用户/Agent 写入 `<root>/scripts/<id>.json`（同 id 覆盖内置）。
- 匹配：`url_pattern` 正则 > 精确 host > host 后缀；同分比 `priority`。
- 脚本 JSON 字段：`id/name/created_by(builtin|user|agent)/origin_url/
  match{hosts,path_prefix,url_pattern}/ready_selector/next_selector/priority/enabled/
  created_at/updated_at/body(返回 JSON 字符串的 JS IIFE)`。
- 一次挂载，`web_search` 与 `webview_extract` 共用，重启保留；复用靠 URL 模式（同站不同 query 命中）。

### 6.4 Agent 闭环

`webview_fetch(outline)` → `webview_fetch(html, selector)` → 写脚本 →
`webview_extract` 验证 → `webview_script_mount` 持久化 → 后续搜索/提取自动复用。

### 6.5 手动搜索页（GUI 验证台）

- 选引擎 + 输入关键词，复用与 `web_search` **同一实现**；列表展示标题/URL/摘要。
- 单击条目 → 系统浏览器打开；条目「解析」按钮 → 隐藏 WebView 渲染该 URL 展示文本。
- 开关：相关性过滤 on/off（关=只去重截断，看引擎直出）；完全原始（不去重不筛不截断）。
- 聚合页数设置；翻页诊断提示与 paging.log 记录。

---

## 7. 会话功能

| 功能 | 说明 |
| --- | --- |
| 创建向导 | 分步：起点（空白/模板）→ 模型（provider+model+参数）→ 系统提示 → 工具与预算 → 存储与标识（sandbox/标题/标签/thinking_reply_mode）→ 生成 id 落盘进聊天 |
| 提示词三段式 | 系统提示词由三段组成：**会话提示词**（模板带入或手写）/ **项目提示词**（所选项目自带，开关「启用项目提示词」并入）/ **新增提示词**（本次会话临时追加）；非空段之间用 `\n---\n` 分隔，顺序固定 |
| 项目提示词 | 项目编辑面板（新建/编辑项目对话框）可写「项目提示词」，随项目 XML 落盘；新建会话页按开关并入该提示词 |
| 会话模板 | 新建/编辑/复制/删除/「用此模板新建会话」；模板向导含 LLM 生成/改写系统提示词 |
| 首页模板选择 | 欢迎页「会话模板」下拉：选中只显示模板名，**发送对话时才创建会话**；未选时用设置里的默认会话模板；两者都无则发送时提示先选模板或去配置默认模板 |
| 克隆（3 种） | ①到首个 user 为止（含）②到首轮结束 ③全量复制；新 id、时间戳=now、tool_calls/usage 清零，保留配置 |
| 编辑重发 | 定位最后一个 `<user>`，删除其后所有元素，替换内容，重算 tool_calls 与累计 usage，立即重发 |
| 重新生成 | 删除最后一条 assistant（及其后 tool 结果）后重发 |
| 删除消息 | 删单条消息（assistant 带 tool_calls 时连带其后 tool 结果；system 不可删），重算计数 |
| 自动命名 | LLM 按首轮生成标题（§3.3），亦可手动重命名 |
| 会话压缩 | §3.3；进度流式展示，可选提示词，产物为摘要 handoff |
| 归档 | 会话/项目归档与恢复（§1.6） |
| 标签 | 会话多标签，列表按标签筛选；全局标签汇总 |
| 项目分组 | 项目=会话分组 + 共享沙箱 + 默认 provider/model；项目行「+」直接新建会话；项目级重命名/归档/删除 |
| 编辑器打开 | 外部编辑器命令模板（`{file}` 占位，如 `code --goto {file}`），未配置用系统默认程序；移动端/无外部编辑器时用**内置 XML 编辑器**（等宽字体、保存前 XML 校验）；保存后自动重载 |
| 打开工作目录 | 系统文件管理器打开会话 sandbox（open/explorer/xdg-open） |
| 多会话并行 | 控制器按会话 id 全局持有，切换不中断后台流式对话；进行中会话在边栏显示旋转圈 |
| 导入/导出 | 会话 XML 导出；工具配置 JSON 导入/导出（§5.3） |
| 搜索/筛选 | 会话列表搜索、按标签/项目筛选、按更新时间排序 |
| 会话信息 | 会话列表「三竖点 → 查看会话信息」：完整会话 XML 路径（可复制）、system 元素 token 用量（input/output/cache/context，K/M/B 两位小数）、模型/思考开关/思考档位、启动的工具（已启用 + 已调用）、完整系统提示词、created/updated 时间 |

---

## 8. 全局配置（config.json）

| 配置 | 说明 |
| --- | --- |
| `providers[]` + `current_provider` + `current_model` | 服务列表与当前选择 |
| `default_params` | 默认模型参数（SessionParams） |
| `default_tools` / `default_tool_calls_limit` | 新会话默认工具与预算 |
| `continue_mode` / `continue_prompt` / `max_tool_calls_per_turn` | 续判模式/模板/单轮上限 |
| `editor_command` | 外部编辑器命令 |
| `theme_mode` | system/light/dark |
| `window_size` | 桌面窗口尺寸预设（下次启动生效） |
| `max_attachment_bytes` | 单图体积上限 |
| `search_engines[]` | 搜索引擎列表（§2） |
| `proxy` | http_proxy/https_proxy/no_proxy（可仅作用于 http_fetch） |
| `tool_approvals{}` | 每工具审批等级 0..3 |
| `shell_level1_commands` / `shell_level2_commands` / `shell_denied_commands` | Shell 正则名单 |
| `compress_prompts[]` | 压缩提示词预置 |
| `default_template_id` | 默认会话模板（首页未指定模板时按它建会话；空 = 未配置） |

### models.dev 集成

- 拉取 `models.dev/api.json` 缓存为 `models_dev.json`；回退链：联网 → 上次缓存 →
  内置裁剪快照 `assets/models_dev/models_dev.json`（约 1.2MB，仅 OpenAI 兼容端点、
  每提供商最新 50 模型）。
- **一键同步**（模型服务页⟳）：按 ID → 端点 host → 预设别名匹配条目；更新模型清单
  （保留用户条目与顺序，剔除 deprecated/专用类型，按发布日期追加支持工具调用的新模型）、
  写入 `model_specs`（上下文窗口/输出上限/能力）、端点仅在为空/同 host/内置默认时改写；
  自定义镜像、API Key、Headers、思考回发设置**永不覆盖**；由 `reasoning_options` 与
  `interleaved` 推导 `reasoning_style`/`reasoning_source`（仅补全 custom 服务）。
- 编辑页「从 models.dev 填充」整表填充；添加向导：搜提供商 → 勾模型（默认预选最新 10 个
  支持工具调用的，可搜索/全选/清空）→ 生成预填服务（ID 去重、命中预设沿用其思考方式）。

---

## 9. UI 页面与组件

### 9.1 页面

| 页面 | 功能点 |
| --- | --- |
| 首页 HomePage | 自适应布局：宽屏左会话列表+右聊天；窄屏列表↔聊天路由。边栏：搜索、项目分组（行尾「+」新建、更多操作菜单）、会话项（进行中显旋转圈）、右键/长按菜单（查看会话信息/重命名/克隆/编辑重发/导出/编辑器打开/打开工作目录/归档/删除）；AppBar：手动搜索、归档、设置、模板、工具管理、模型服务等入口 |
| 聊天面板 | 头部（模型选择器/执行模式/用量/上下文条）、消息流（用户右/助手左）、实时流区域、状态栏、压缩进度弹窗、审批弹窗/列表 |
| 创建向导 | 分步表单（§7） |
| 模板页 + 模板向导 | 模板 CRUD；向导分步 + LLM 生成/改写系统提示词（含场景类别） |
| 模型服务页 | provider 列表/编辑（baseUrl/apiKey/headers/预设/思考参数/模型清单/model_specs）、**最大输出 tokens（数值输入，作为请求体的输出上限；留空=不限制）**、**输出上限参数名（`max_tokens` / `max_completion_tokens`，前者通用、后者为 OpenAI o 系列 / gpt-5 必填）**、测试连接、拉取模型、models.dev 同步/填充/添加向导；API Key 字段支持显示/隐藏切换与「从剪贴板粘贴」（Android 输入法禁止在密码型输入框粘贴，故提供 App 侧剪贴板按钮兜底） |
| 设置页 | 数据目录（展示/打开/迁移/申请外部存储权限）、外部编辑器、主题、窗口尺寸、默认参数（temperature/top_p/max_tokens/思考开关）、默认工具与工具上限、续判模式与提示词、单张图片上限、**默认会话模板（从会话模板中选一）**、代理（http/https/no_proxy、仅 http_fetch）、搜索引擎管理（增删改排序、选择器、聚合页数）、压缩提示词维护、字体显示测试、本机信息、打开 config.json |
| 工具管理页 | 每工具审批等级、shell 三名单编辑（正则校验/一键默认）、shell 审批详情、工具配置 JSON 导入/导出 |
| 手动搜索页 | §6.5 |
| 归档页 | 已归档会话/项目列表，恢复/删除 |
| 压缩提示词页 | 预置压缩提示词增删改 |
| XML 编辑器页 | 内置编辑（移动端），保存前 XML 校验 |
| 字体测试页 | 字体渲染/来源探测（调试用） |

### 9.2 消息与输入组件

- **消息气泡**：Markdown 渲染（代码高亮/表格/列表/安全代码块/斜体引用块处理、
  KaTeX 公式 `$…$` `$$…$$` `\(…\)`，含复制回退）、
  时间/操作按钮（编辑重发、重新生成、删除、复制…）。
- **思考块**：可折叠，默认折叠，流式时自动展开；标注来源模式（reasoning_content/think_tag）。
- **工具调用块**：命令 + 参数 + 结果摘要，可展开全文；错误态样式；流式参数增量展示。
- **用量角标**（UsageBadge）：单条 in/out/cache；状态栏累计 + 上下文条
  （context / 模型上下文窗口占比，窗口来自 model_specs 或手动配置）。
- **输入区**：多行编辑；Enter 发送 / Ctrl+Enter 换行（可切换「Enter 换行」模式）；
  发送/停止按钮；添加图片（多选、格式与体积校验、缩略图、可移除）；
  web_search 工具开关（本轮是否携带）；执行模式切换（普通/自动/托管）；
  压缩会话入口；回到底部/回到最近消息按钮。

### 9.3 通用

- 主题亮/暗/跟随系统；内置字体 NotoSansSC + JetBrainsMono；
- 确认对话框组件；错误视图；快捷键（Enter 发送/Ctrl+Enter 换行/Esc 停止等）。

---

## 10. 平台差异

| 平台 | 要点 |
| --- | --- |
| Android | App 私有数据目录；可申请外部存储权限迁移数据；系统 WebView；单 Activity |
| iOS/macOS | 系统 WebView（WKWebView）；Documents 目录 |
| Windows | 系统 WebView2；`start` 打开文件/目录 |
| Linux | WebKitGTK 4.1（`libwebkit2gtk-4.1-dev`）；`xdg-open` |
| 桌面通用 | shell 工具、外部编辑器、窗口尺寸记忆、打开工作目录 |

---

## 11. 测试与构建（重写时的验收基线）

- 单测覆盖：XML round-trip（CDATA/思考/usage）、会话操作（克隆/编辑重发）、
  压缩、附件、模型目录、提示词工具、沙箱解析、搜索引擎配置、搜索过滤、shell 策略、
  索引仓库、版本号、首页流程。
- `llm_api` 包单测：OpenAI 兼容 / Anthropic / Gemini 协议、SSE 解析、会话工具循环、
  think 标签解析。
- CI：Android APK、Linux deb（依赖 `libwebkit2gtk-4.1-dev`，deb 运行时依赖
  `libwebkit2gtk-4.1-0`）、Windows 构建工作流（zip 按版本命名
  `xchat-windows-x64-vX.Y.Z.zip`）+ GitCode 同步脚本。

---

## 12. 重写要点速查（易漏的"隐性契约"）

1. XML 文本必须 CDATA（不转义），属性承载 usage 数值，缺失≠0。
2. `system` 元素即使内容为空也保留——它是累计 usage 的载体。
3. `tool_calls` 计数**累计**与**本轮预算**是两个概念，续判重置后者。
4. 思考回发是硬需求：开启思考就必须回发，形态按 provider 分字段式/标签式。
5. 图片必须紧跟 tool 消息后单独成条 user 图片消息（协议限制）。
6. 审批队列必须全局化，否则切换会话会丢审批导致工具被静默拒绝。
7. shell 三名单任一为空 ⇒ shell 整体禁用；F>2>1>base 优先级。
8. 搜索只能走隐藏 WebView；翻页必须"验证结果集变化"，且白跑一轮要重试。
9. 写盘原子（tmp+rename）；index.json 需与磁盘比对防多实例漂移。
10. models.dev 同步不得覆盖用户自定义（镜像地址/API Key/Headers/思考调优）。
