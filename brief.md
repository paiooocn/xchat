# XChat 项目代码摘要

> XChat 是一个基于 Flutter + H5/WebView 的跨平台 LLM Agent GUI,后端(Dart)+前端(HTML/CSS/JS)全在同仓。
> 持久化: `~/.xchat/`(config.json / sessions/*.xml / templates/*.xml / projects.json / logs/*.log)。
> 通信: Dart ↔ WebView 通过 `JavaScriptChannel('XchatNative')`,事件用 `BridgeEvents` 总线,本地 HTTP 服务绕开 WebKit `file://` 限制。
> 许可证: MIT(见根目录 `LICENSE`,Copyright (c) 2026 XChat Authors)。

---

## 1. 入口与壳层

### `lib/main.dart`
- `main()`: 初始化 `ConfigManager` + `BlocklistLoader`,后台拉汇率,启动 `XChatApp`。
- `XChatApp`: `MaterialApp`,`home = WebViewHost`。

### `lib/ui/webview_host.dart`
- `WebViewHost` / `_WebViewHostState`: 注册 `XchatNative` JS 通道,把收到的 `{method, args, cb}` 转给 `BridgeApi.handle`,用 callback 名回灌结果。
- 启动 `LocalWebServer`,通过 `http://127.0.0.1:port/` 加载 `assets/web/index.html`(解决 WebKit 子资源跨文件加载)。
- 订阅 `BridgeEvents` 全部事件,转 JS 端 `window._xchat_dispatch(event, payload)`。

### `lib/ui/local_web_server.dart`
- `LocalWebServer`: 绑 loopback,纯静态服务 `assets/web`,内置 MIME 表,过滤 `..`、绝对路径,只 GET/HEAD。
- 单例 `start(root)` / `stop()` / `baseUrl`。

---

## 2. 桥接层

### `lib/bridge/bridge_api.dart`
- `BridgeApi.handle(method, args)`: 巨型 switch,实现 H5 调用的所有 RPC:
  - **config**: `get` / `set` / `refreshFx` / `getBlocklist` / `setBlocklist` / `setConfirmMode` / `setEditor`(空串/null 视作未配置,回退到 `$EDITOR`)
  - **sessions**: `list`(query+tag+project_id)、`get` / `create`(走模板 + 写 project/tags)/ `delete` / `clone` / `resend` / `openInEditor` / `updateMeta` / `setTags` / `setProject` / `listTags` / `listTemplates` / `getTemplate`
  - **templates**: `list` / `get` / `save` / `delete` / `duplicate` / `listVars` / `openInEditor`
  - **projects**: `list` / `create` / `rename` / `delete`(级联清空会话的 `projectId`)
  - **providers**: `list` / `get` / `upsert` / `delete` / `test`
  - **chat**: `send`(异步 `ReactLoop.run`)/ `stop`(`ReactLoop.stop`)/ `confirmTool`(`BridgeEvents.resolveConfirm`)
- 工具:`_serialize(ChatSession)` / `_providerToJson` / `_providerFromJson` / `_openInEditor` / `_openTemplateInEditor` / `_emptyUserTemplateXml`。

### `lib/bridge/bridge_events.dart`
- `BridgeEvents`: 广播 `StreamController` 字典 + `_pendingConfirm` 等待表。
  - `on(event)` / `emit(event, payload)`
  - `waitForConfirm(sessionId, callId)` / `resolveConfirm` / `cancelPendingConfirms`
- `_ConfirmWaiter`: 单次承诺包装。

---

## 3. Agent 核心(ReAct + 压缩 + Token)

### `lib/agent/react_loop.dart`
- `ReactLoop.run(session, userText)`: 主循环。流程: 追加 user → `_buildMessages` → `OpenAiValidator.validate` + `normalize`(失败立即终止)→ 调 `LlmClient` → 写 assistant(含 token,session_io 新 XML 格式下 assistant 内嵌 `<tool_calls><tool_call/></tool_calls>`)→ 必要时 `Compressor.compress` → 若 `tool_calls` 空则 done;否则按 confirm 决策执行 `ToolRegistry.execute`,`BlockedLayerA` / `BlockedExceptionYolo` 中断 → 工具结果以 `<tool tool_call_id="...">` 同级元素写盘,与接收数据顺序一致。
- 满 `maxRounds` 自动 `clone(newId)` 续会话,emit `session_continued`。
- `stop()` / `_stopRequested`: 协作式停。
- **多轮连续性**:每轮 LLM 调用的开始/结束(请求了几次 tool、协议校验失败、LLM API 错误、blocked_*)都 `print('[XChat][react_loop] ...')` 到控制台,便于排查"只跑一轮就停"问题。
- **停止信号**:`ReactLoop.stop()` 后 emit `stopped` 事件(而非 `done`),前端 chat 页面据此关闭运动图标并解除输入框禁用。
- `_buildMessages`: 严格按 OpenAI 协议排列 system/user/assistant(+tool_calls 紧跟 tool 结果)。
- 修复记录: 丢弃孤立 tool 元素、assistant 后强制带 tool 结果、避免 onChunk 死等、assistant{tool_calls}+null content 统一改 ''。
- **一轮对话后卡死修复(2026-Q1)**:
  - **#1 头三行 try/catch**:`ReactLoop.run` 入口追加 user + `SessionIo.write` + emit `user_appended` 整段包 try/catch,失败时 emit `error` + 返回 `RunKind.error`。防止 IO/磁盘错误把异常抛到 `chat.send` 处理器的 `unawaited_futures` 上,导致前端永远收不到 `done`。
  - **#2 SSE 60s 超时**:`LlmClient._callOpenAI` 与 `_callAnthropic` 的 stream `.timeout(Duration(seconds: 60))`,超时后 catch `TimeoutException` 返回 `ERROR: stream_timeout_60s`,由 `ReactLoop` 已有路径发 `error` 事件。修复带 keepalive 的 OpenAI 兼容服务不发 `[DONE]` 且不关连接导致 `await for` 无限等待的问题。
  - **#3 TokenTracker fire-and-forget**:`ReactLoop.run` 中 `await TokenTracker.apply(...)` 改为 IIFE 异步调用且不 await,异常自身吞掉不污染主调用栈。防止同步 `writeAsString(flush: true)` 在杀毒软件/外力打断下阻塞主循环让前端 disabled 期间看起来卡死。
  - **#4 事件 ready 前缓冲回灌**:`BridgeEvents` 在 WebView 端 JS mount 之前累积所有 `emit` 进 `_eventLog/_eventNames`;`assets/web/js/bridge.js` mount 完成后自动调 `chat.notifyReady`,Dart 侧 `chat.ready` 处理器 `BridgeEvents.drainPending()` 把累积事件一次性回灌给 JS,前端就能补齐 setRunning(false) 所需的 done/error/stopped。解决首次 `chat.send` 时 JS 还没 subscribe、`runJavaScript` 调 `_xchat_dispatch` 是 no-op、事件被静默丢弃的元凶。
  - **#5 chat.send 立即返回 + 后端 read**:`bridge_api.dart` 的 `chat.send` 不再 `await SessionIo.read(sid)`(IO 卡住时 RPC 永不返回 + 前端 await 不进 setRunning(true),输入框清空后无任何反馈表现为"卡死"),改用 `ReactLoop.runById(sid, text)` 内部 read;read 失败立刻 `BridgeEvents.emit('error')`,run 异常也兜底 emit。RPC 同步返回 `ok:true`,前端进入正常事件流。
  - **main.dart 空 unawaited 实现**:删除 `void unawaited(Future<void> f) {}` 空壳,改用 `dart:async` 的真实现。原空实现不会启动 Future,`FxRates.refresh(silent: true)` 永远不跑;不影响 chat 卡死但属于隐藏 bug。

### `lib/agent/compressor.dart`
- `Compressor.shouldCompress(s)`: `sysContext >= limit * threshold`。
- `_contextLimit(s)`: 读 `defaults.model_param.context_window` → 回落 provider 的 `model.context`。
- `compress(s, keepRounds=3)`: 切分旧/新 → `_summarize` → 旧段塞 `archive` + 摘要,新段头部加 `[历史摘要]` user,重置 token 累计,写盘。
- `_summarize`: 临时 `ChatSession` 调 `LlmClient`;失败回退 `_fallbackSummary`。
- `_fallbackSummary`: 拼前 5 个 user + 首个 assistant 摘要。

### `lib/agent/llm_client.dart`
- `LlmUsage(input, output, cacheRead, cacheWrite)` / `LlmResponse(text, toolCalls, usage, model?)`
- `LlmClient.call(session, messages, onChunk)`: 按 provider `type` 派发 `_callOpenAI` / `_callAnthropic`,统一流式 + usage 收集 + tool_calls 累积。
- `_openAIToolSchema(name)`: 8 个内置工具的 JSON Schema。
- `_mapReasoningEffort`: 内部值 → OpenAI 接受值映射。
- **异常日志**: HTTP 非 200 / 流式 JSON 解析失败都 `print('[XChat][llm_client] ...')`,便于排错。
- **请求/响应落盘**: 已下线,见 `lib/util/llm_logger.dart` 一节。

### `lib/util/llm_logger.dart`
- 已移除。LLM API 请求/响应日志(此前落盘到 `~/.xchat/logs/llm/YYYY-MM-DD.jsonl`)在简单对话场景下导致"会话结束时应用卡死",暂时下线该功能,避免日志 IO/序列化对 `BridgeEvents.emit('done')` 派发的干扰。后续如需重新引入,需先解决 `_tail` future 链与主调用栈的微任务竞争问题。

### `lib/agent/openai_validator.dart`
- 发送前校验 OpenAI Chat Completions 协议:
  - messages 非空、首条 role ∈ {system,user}
  - 每条消息 role/字段类型(content/tool_call_id/tool_calls)
  - `tool_calls[].function.arguments` 必须是合法 JSON String
  - 配对校验:`assistant{tool_calls[i].id}` 必须紧跟 `tool{tool_call_id == id}`,否则报 `unconsumed`
- `OpenAiValidator.normalize(msgs)`: 把 assistant 含 tool_calls 且 content 为 null 的统一改为 `''` —— 部分 OpenAI 兼容服务(vLLM/Together)会拒收 `null`,改成空串最大化兼容。
- 被 `ReactLoop` 在每次 LLM 调用前调用,失败时直接终止 run 并把错误回填到 assistant 消息。

### `lib/agent/token_tracker.dart`
- `TokenTracker.apply(s, msg, usage)`: 写 assistant 属性 + 累加 `sysInput/Output/Cache/Context` + 写盘。

### `lib/agent/run_result.dart`
- `enum RunKind { done, blockedLayerA, blockedExceptionYolo, error }`
- `class RunResult { kind, message }`

---

## 4. 会话 / 模板 / 项目

### `lib/session/session_model.dart`
- `enum Role { system, user, assistant, tool }`
- `ChatMeta`: providerId/modelId/thinking/reasoningEffort/temperature/toolOutputLimit/contextCompressThreshold/confirmMode/allowSymlinks + 3 个 shell blocklist 字符串字段(预留)。
- `ToolDef(name, enabled)` / `ToolCall(id, name, arguments)` / `Message(role, text, toolCallId, toolName, toolCalls, input, output, cache, model)`.
- `ChatSession`: id/sandbox/title/created/updated/maxRounds/meta/systemPrompt/sys{Input,Output,Cache,Context}/tools/messages/archiveSummary/archive/projectId/tags。
- `context` getter、`firstUserText(limit)`、`clone(newId)` 完整深拷贝。

### `lib/session/session_io.dart`
- `SessionIo.write(s)`: 把 `ChatSession` 序列化为 XML(基于 `XmlWriter`): `<chat>`/`<meta>`/`<system>`(CDATA)/`<tool>`(定义)/`<user|assistant|tool>`(消息)/`<archive>`。
  - **assistant 含 tool_calls 时**:`<assistant>` 下内嵌 `<tool_calls><tool_call id name>{arguments CDATA}</tool_call></tool_calls>`,顺序与 `Message.toolCalls` 一致;assistant 原文本作为 `<text>CDATA</text>` 子元素保留。
  - **tool 结果消息**:作为 `<assistant>` 的同级元素(直接在 `<chat>` 下),用 `tool_call_id` 属性标记。
  - **tool 定义** vs **tool 结果消息**:同名 `<tool>`,靠 `tool_call_id` 属性区分——有是结果消息,无是工具定义。
- `SessionIo.read(id)`: `XmlReader` 解析 → `_parseChat` 重建对象。新格式:从 `<tool_calls>/<tool_call>` 子树读 toolCalls;旧格式(CDATA 内嵌 `[[tool_calls]]` 标记块)走兜底解析路径,保持向后兼容。
- `sessionsDir()`: `~/.xchat/sessions/`。

### `lib/session/session_list.dart`
- `SessionListItem { id, updated, created, sandbox, title, providerId, modelId, totalInput, totalOutput, totalCache, projectId, tags }`。
- `SessionList.list(query?, tag?, projectId?)`: 扫所有 session.xml,按 tag/projectId 过滤,标题子串搜,按 updated 倒序。
- `SessionList.search(q, tag?, projectId?)`: 全文搜所有 message CDATA。
- `SessionList.delete(id)`: 删文件。

### `lib/session/session_ops.dart`
- `cloneFull(id)`: 整段克隆(新 id + "(副本)" 标题)。
- `cloneEmpty(id)`: 只克隆 meta + system + tools。
- `resend(id, text)`: 找最后 user,替换文本并截断后续。

### `lib/session/templates.dart`
- `Template(id, name, description, xml, vars, editable)`: `vars` 从 `{{name}}` 提取并排序去重;`render(vars)` 做替换。
- `TemplateRepo`:
  - 用户目录: `~/.xchat/templates/`(`_userDir()`)
  - `list()`: 内置 3 个(builtin:blank / builtin:coder / builtin:research) + 用户 xml。
  - `get(id)` / `save` / `delete` / `duplicate(sourceId, newName)` / `listVars` / `create(...)`: 把渲染后的 `<template>` 拆出 `<system>` 文本、`<tools>`、`<meta.max_rounds>`,构造 `ChatSession` 写盘。

### `lib/session/project_repo.dart`
- `Project(id, name, color, created)` + `toJson/fromJson`。
- `ProjectRepo.list/create/rename/delete`: 持久化 `~/.xchat/projects.json`,`create` 时按数组下标从 `_defaultColors` 选色。

---

## 5. 配置 / Blocklist / 汇率 / Provider

### `lib/config/config_manager.dart`
- `ConfigManager` 单例: `~/.xchat/` 下建 sessions/templates/logs,`config.json` 加载/保存。
- `init()` / `initForTest(dir)` / `patch(updates)`(深合并)/ `data`(防外部改)/ `xchatDir` / `configFile`。
- 默认 `config.json` 结构: `providers[]` / `defaults.provider_id|model_id|max_rounds|model_param|tool_output_limit|context_compress_threshold|summarizer` / `ui.currency|fx_rates|fx_fetched_at|theme|confirm_mode|editor`。
  - `ui.editor` 控制"在编辑器中打开 xml"的命令;null 时回退到 `$EDITOR` 环境变量,再回退到 `vi`。值是命令行字符串(空格分隔,支持引号),无 `{}` 占位则把文件路径追加到末尾,有 `{}` 则替换。
  - 设置页(`assets/web/js/pages/settings.js`)有专门的"外部编辑器命令"卡片:输入框 + 保存/清除按钮 + 实时预览(预览逻辑用同一套分词+占位规则,与 Dart 端 `_resolveEditor` 对齐)。

### `lib/config/blocklist_loader.dart`
- `BlockRule(pattern, note)` 自带 `regex = RegExp(pattern)`。
- `Blocklist { layerA, layerB, layerBExceptions }`。
- `BlocklistLoader` 单例: 加载/热重载 `~/.xchat/shell_blocklist.xml`;缺失时从 `bin/default_blocklist.xml` 拷过来;`save(...)` 写出并 reload。
- `describeLayerA/B` 供 UI 展示。
- `bin/default_blocklist.xml`: 默认三层规则(rm -rf /、sudo、mkfs、dd 覆盖块设备、shutdown/reboot、fork 炸弹、chmod 777、su、fdisk/parted 等为 layer_a;npm/pip/cargo/apt/git push 等为 layer_b;绝对路径 rm -rf /、curl|sh 为 layer_b_exceptions)。

### `lib/config/fx_rates.dart`
- `FxRates`: 启动拉 `https://api.exchangerate-api.com/v4/latest/USD`,5s 超时,失败用静态 `USD/CNY/EUR/JPY`,成功后回写 config。
- `refresh(silent)` / `rates` / `fetchedAt` / `currency` / `isStale`(>30 天)/ `convertUsd(usd, to?)`。

### `lib/config/provider_repo.dart`
- `ProviderSpec(id, type, baseUrl, apiKey, models)`: `type ∈ {openai_compatible, anthropic}`。
- `ModelSpec(id, context, pricing{in,out,cache}, thinking?, reasoningEffort?, temperature?)`(CNY/1M tokens,用于成本面板;thinking/reasoning/temperature 均为可空,null = 不传入该参数,沿用 `ChatMeta` 默认或 LLM 服务端默认)。
- `ProviderRepo.list/get/upsert/delete`: 读 `config.json` 的 `providers` 数组。
- `ProviderRepo.test(id, modelId?)`: 按 type 发最小请求(max_tokens=1),8s 超时,返回 `{ok, latency_ms, status, error?}`。

---

## 6. 工具

### `lib/tools/path_guard.dart`
- `PathEscapeError(sandbox, attempted)`.
- `PathGuard.resolve(sandbox, userPath)`: 拼绝对路径再 `canonicalize`,校验必须在 sandbox 内,越界抛 `PathEscapeError`。Windows 不解析大小写。

### `lib/tools/file_tools.dart`
- `readFile(sandbox, path)` / `writeFile` / `editFile(find, replace, allOccurrences)` / `listDir(sandbox, path, hidden=false)`: 返回 `d/f <name>` 行,过滤 `.` 开头。
  - **writeFile**: 自动 `mkdirs(recursive: true)` 创建父目录,LLM 写深层路径不再因父目录缺失而失败。
  - **editFile**: 目标不存在时降级为 write_file 语义(常见用法是创建新文件),父目录同样自动创建。
  - **readFile/listDir**: 目标不存在时返回 `ERROR: file_not_found: <path>` / `ERROR: directory_not_found: <path>`,而不是抛异常。
- `glob(sandbox, pattern)`: 极简 `*` + `**` 支持,递归扫目录;base 不存在时返回空字符串而非崩溃。
- `grep(sandbox, pattern, path?, ignoreCase?)`: 行级正则,输出 `path:line:text`;无匹配返回 `(no matches)`,目录不存在返回 ERROR。
- 所有工具错误路径都返回明确带路径前缀的 ERROR 字符串,便于 LLM 定位。

### `lib/tools/shell_tool.dart`
- `enum ShellResultKind { ok, blockedLayerA, blockedExceptionYolo, userDenied, error }`、`ShellResult`。
- `ShellTool.execute(sandbox, cmd, confirmMode)`:
  1. 扫 layer_a → 命中即 `blockedLayerA`。
  2. 扫 layer_b;若命中再扫 layer_b_exceptions,`yolo` 模式下例外也拒绝(`blockedExceptionYolo`)。
  3. `Process.runSync('/bin/sh', ['-c', cmd], workingDirectory=sandbox)`,stdout+stderr 合并,>8000 字符截断并加 `[truncated]`。

### `lib/tools/tool_registry.dart`
- `safeTools = {read_file, list_dir, glob, grep, get_time}`。
- `dangerousTools = {shell, write_file, edit_file}`。
- `shouldConfirm(name, mode)`: `yolo` → false;`shell` → 仅 shell;`normal` → dangerous。
- `isDangerous(name)`.
- `execute(name, sandbox, args, confirmMode='normal', alreadyConfirmed=false)`: switch 派发;路径错误 `PathEscapeError` 包成 `ERROR: path_escape`;`shell` 的 layer_a/exception_yolo 抛 `BlockedLayerA` / `BlockedExceptionYolo`(由 `ReactLoop` 捕获,中断 run)。
- **路径日志**(便于排查"工具返回 OK 但找不到文件"):
  - 入口 `_logToolCall` 一行 `[XChat][tool] call name=... sandbox=... path=<相对> abs=<解析后绝对路径> bytes=N`,解析失败附 `path_escape=...`;`glob` 打 `pattern`、`shell` 打 `cmd`。
  - 写入类工具(`write_file`/`edit_file`)完成后 `_logToolResult` 打 `[XChat][tool] result ... ok=true|false exists_after=true|false size_after=N err=...`,直接告诉用户文件是否真在磁盘上。
- 异常类 `BlockedLayerA`、`BlockedExceptionYolo`。

---

## 7. 工具类

### `lib/util/uuid.dart`
- `uuidV4()`: `Random.secure` 生成 8-4-4-4-12 段。

### `lib/util/xml_writer.dart`
- `XmlWriter`: 保留旧 `open/close/selfClose/element/cdataElement/decl` 流式 API。
- CDATA 内的 `]]>` 转义为 `]]&gt;` 以保证 XML 合规,reader 端再反向解码。
- 属性/文本完整 entity 转义;`output` 返回串。

### `lib/util/xml_reader.dart`
- `XmlElement(tag, attrs, children, text)`: 内部适配层。
- `XmlReader.parse(input)`: 调 `package:xml`,把所有 text/CDATA 合并到 `text`(`]]&gt;` 还原为 `]]>`),元素下钻到 `children`。
- `XmlParseException`.

### `lib/util/logger.dart`
- `Logger.appendToolExec(sessionId, name, args, result)`: 追加写 `~/.xchat/logs/<id>.log`,5MB 滚动到 `<id>.1.log`(用于 yolo 模式审计)。

---

## 8. 前端 H5(`assets/web/`)

### `index.html`
- 加载顺序: `css/base.css`、`css/theme.css` → `js/bridge.js` → `js/markdown.js` → `js/router.js` → 各 page IIFE → `Router.init()` + `Router.go('#/sessions')`。

### `assets/web/js/pages/chat.js`
- **对话进行中状态显示**:移除头部右侧的 `<span id="runningIndicator">`;改为 `[发送]` 按钮变 spinner(`<span class="spinner">`,按钮加 `.sending` 类)。同时禁用输入框 + `placeholder` 改为"对话进行中,请等待结束…";结束时按钮恢复"发送"。
- **tool_call 内容渲染**(`renderToolCall`):单个 tool_call 默认展示前 5 行 arguments + `...`;超过 5 行用 `<details>` 折叠,summary 显示行数,展开后看完整内容。少于等于 5 行则直接展示,不再折叠。
- 状态机 `isRunning`:
  - 触发 `true`:`chunk` / `user_appended` / `tool_start`
  - 触发 `false`:`done` / `error` / `stopped` / `blocked_layer_a` / `blocked_exception_yolo`
- CSS `@keyframes btn-spin` 0.9s 线性旋转,遵循 `prefers-reduced-motion` 关闭动画。

### `js/bridge.js`
- 在所有页面 IIFE 之前挂 `window.xchat`,抢先用 `setInterval(100ms)` 轮询 `_xchat_native` 就绪后 flush 队列。
- 三路发送: `_xchat_native.postMessage` → `window.webkit.messageHandlers.XchatNative.postMessage` → 5s 超时兜底。
- 完整 xchat API: `config.*` / `sessions.*`(含 setTags/setProject/listTags)/ `templates.*` / `projects.*` / `providers.*` / `chat.*` / `events.on`。
- 暴露 `window._xchat_dispatch(event, payload)` 给 Dart 推送事件。

### `js/markdown.js`
- `Markdown.render(text)`: 极简 markdown 渲染(供 chat 消息展示)。

### `js/modal.js`
- 统一 H5 弹窗封装,代替浏览器原生 `confirm()/prompt()`,WebView 中不会被屏蔽、不阻塞渲染。
- API: `Modal.confirm({title, message, confirmText, danger})` / `Modal.prompt({title, label, value, placeholder, multiline, choices})` / `Modal.alert({title, message})` / `Modal.view({title, body, message})`(只读 + 一键复制,用于查看 XML)/ `Modal.color({title, value, presets})`(色盘:16 预设色 + `<input type="color">` 自定义,选色即时预览)。
- **修复记录**: 旧版 `Modal.confirm` 返回 `box._promise`(永不被赋值),导致所有 `await Modal.confirm()` 永远 hang。表现为"右键删除会话 → 确认 → 无反应"。已改为返回 `open()` 创建的 promise。
- 弹窗支持 `Esc` 关闭、点击遮罩关闭、`Enter` 触发主按钮(单行输入时)。

### `js/theme.js`
- 主题管理: `light` / `dark` / `system`。
- `XchatTheme.apply()` 在 `DOMContentLoaded` 时执行,优先用 `config.ui.theme`,回落到 `localStorage['xchat.theme']`,再回落到 `system`。
- `matchMedia('(prefers-color-scheme: dark)')` 监听系统变化,system 模式下实时跟随。
- `setMode()` 写 localStorage + `config.set({ui:{theme}})`。

### `js/router.js`
- `Router.init/on/go/render`: hash 路由(支持 `:param` 与 `RegExp`);`render` 统一壳(topbar 含 [设置] 入口 + `#main`),每次切换同步主题到 `#theme-indicator`。

### `js/pages/session_list.js` → `#/sessions`
- 顶部搜索 + 新建;tabs: 全部 / 各项目(带色点)/ 各标签(带计数)。
- 列表项: 标题、provider/model、tokens 合计、相对时间、tag chip。
- 右键/长按菜单: 克隆(含历史)、**以此建新会话**(`xchat.sessions.cloneMeta`,只复制 chat 属性/meta/system/tools/项目/标签,不带历史消息)、编辑器打开、设置标签(`Modal.prompt`)、移到项目(`Modal.prompt` + choices)、删除(`Modal.confirm`)。
- 全部用 `Modal.*`,不再用 `confirm/prompt`。

### `js/pages/wizard.js` → `#/sessions/new`
- **单页表单**(2026-09-10 重写):模板卡片列表(选中高亮)→ Provider/Model 下拉 + 模板参数动态字段(从 `template.vars` 提取)→ 高级(默认折叠,sandbox / max_rounds / 项目 / 标签)→ 一键创建。
- 默认值:首个 provider / 首个 model / `builtin:coder` 或首个模板 / sandbox=`/tmp` / max_rounds=20。
- 调 `xchat.sessions.create` 后跳到 `#/chat/<id>`。

### `js/pages/chat.js` → `#/chat/:id`
- 顶部: 返回 / 标题 / 项目色点 / tag chips / sandbox / 累计 usage / 编辑重发 / 编辑器。
- 消息区: `Markdown.render` 渲染 assistant,显示 `in/out/model`。
- 输入区: Enter 发送,Shift+Enter 换行;停止按钮调 `chat.stop`。
- 事件订阅: `chunk`(流式累加)/ `user_appended`(唯一来源,前端不预加)/ `assistant_done` / `tool_start` / `tool_done` / `done` / `blocked_layer_a` / `blocked_exception_yolo` / `compressed` / `confirm_required`(弹模态: 拒绝/允许一次/会话级不再询问)/ `session_continued`(跳新 id)/ `error`。
- 流式: `appendChunk` 用 `__streaming` + DOM `data-streaming="1"` 标记,只更新同一节点 `.msg-body` 的 innerHTML,绝不重复插入;`assistant_done` 收尾时 `renderMessages` 全量重渲。
- "编辑重发" 用 `Modal.prompt({multiline:true})` 多行编辑最后一条 user 消息。

### `js/pages/templates.js` → `#/templates`
- 列表: 内置(只读,带 builtin 标)/ 用户模板;每条支持 **查看**(弹 `Modal.view` 显示原始 XML,内置/用户都能看)、编辑、复制为我的、外部编辑器打开(仅用户)、删除。
- 编辑器页: 名称、描述、XML textarea(实时统计 `{{var}}`)、保存、重新读取文件(已存在的)、外部编辑器。
- **新建流程**: 进入编辑页不预先写盘,仅在内存里维护草稿;点 [保存] 才调用 `xchat.templates.save` 落盘(后端在 `id` 缺省时自动生成 `user:<timestamp>`);点 [← 返回] / [放弃] 时若是新建且未保存,弹 `Modal.prompt(choices: [保存并离开 / 丢弃并离开 / 留在编辑页])`。
- 所有弹窗统一用 `Modal.*`。

### `js/pages/projects.js` → `#/projects`
- 列表 + 新建/重命名/换色/删除;删除会级联把隶属会话 `projectId` 清空(由 Dart 端处理)。
- "换色" 走 `Modal.color`(16 色预设 + `<input type="color">` 自定义 + 实时预览圆点),不再用输入框填 CSS 颜色值。
- 全部弹窗走 `Modal.*`。

### `js/pages/providers.js` → `#/providers`
- 列表 + 测试连接 + 编辑 + 删除。
- 编辑页: id/type/base_url/api_key + 模型表(每行:模型 ID + 上下文窗口 + 输入价格 + 输出价格 + 缓存价格,均带可见 label,行内可单测);保存后做"测"/"用首个模型测"。
- 模型行用 grid 布局(`1.4fr 3fr auto` + 4 列参数),窄屏自动塌成单列;label 标明单位(tokens / **CNY per 1M tokens**)。
- **价格单位约定**: provider 内 `pricing{in,out,cache}` 存储为 **CNY / 1M tokens**;成本面板直接按 CNY 算再换显示币种。Provider 编辑页输入也是 CNY,无货币换算。
- 删除弹窗走 `Modal.confirm(danger:true)`,失败提示走 `Modal.alert`。

### `css/base.css` 新增
- `.model-list / .model-row / .model-row-params / .model-row-actions / .field-label`:Provider 页模型参数编辑行的网格布局与字号。

### `js/pages/cost_panel.js` → `#/cost`
- 选币种 + 刷新汇率(调 `config.refreshFx`)。
- 按 `model_id` 聚合所有会话的 `totalInput/Output/Cache`,按 provider 内 `pricing` 直接折算 **CNY**(价格存储约定是 CNY/1M tokens),再 `CNY / rates.CNY × rates[cur]` 换算到选定显示币种。

### `js/pages/settings.js` → `#/settings`
- **UI 主题**: 浅色 / 深色 / 跟随系统 三按钮,点击立即应用并 `XchatTheme.setMode()`。
- **工具确认模式**: safe / normal / yolo,点击调 `xchat.config.set({ui:{confirm_mode}})`。

---

---

## 变更记录

### 2026-09-10 · 修复:对话完成后应用卡死
- **症状**: 完成一次对话(可见 LLM 响应)后,输入框 + 发送按钮一直 disabled,看起来 UI 卡死。
- **根因**: `lib/agent/react_loop.dart` 的 3 条 return 路径漏发终止事件,前端 `setRunning(false)` 永远等不到:
  1. OpenAI 协议校验失败 → emit `assistant_done`(错误文本)→ return,**无** `done`/`error`/`stopped`
  2. LLM 返回 `ERROR:` → emit `assistant_done` → return,**无** 终止事件
  3. 循环体内任意未捕获异常(典型如 `Compressor.compress` 写盘抛、TokenTracker.apply 抛)→ 异步逃出 `unawaited`,**无** 终止事件
- **次因**: `BridgeEvents.emit('error', ...)` 在整个 Dart 代码里从未被调用,JS 端的 `xchat.events.on('error', ...)` handler(本来就会 `setRunning(false)`)是死代码。
- **修复**:
  - 协议校验路径: emit `assistant_done` 后追加 `emit('error', {...})`
  - LLM ERROR 路径: 在 `return` 之前追加 `emit('error', {...})`
  - 主循环 `while (true)` 外加 `try/catch`,catch 里强制 `emit('error', ...)` 并 `return RunResult(RunKind.error, ...)`,把 Compressor / TokenTracker / SessionIo 等任意未捕获异常兜住
- **验证**: `flutter analyze` 0 issues;`flutter test` 全套 63 个 case 全过。

### 2026-09-10 · 修复:会话列表右键"以此建新会话"无反应
- **根因**: `assets/web/js/bridge.js` 里 `window.xchat.sessions` 被定义两次,第二次整块覆盖第一次,导致第一次里的 `cloneMeta` 被丢弃。点击右键菜单"以此建新会话"时 `xchat.sessions.cloneMeta is not a function`,前端静默吞掉错误,看起来无反应。
- **修复**: 删除第一个 `sessions:` 块(冗余),把 `cloneMeta` 加到第二个(带 `list(q, opts)` / `setTags` / `setProject` / `listTags` 的)块里;只剩一个 `sessions:` 定义,`cloneMeta` 不再丢失。`node --check` 通过。

### 2026-09-10 · 回滚 LLM API 请求/响应 JSON 日志(简单对话场景下卡死)
- **现象**: 加入日志后,执行一次"会话未传工具"的简单对话,在对话结束时(`LlmClient.call` 返回 → `ReactLoop.run` 发 `done` 事件)前端拿不到 `done`,输入框永久 disabled 表现为卡死。
- **排查**: 隔离到 `unawaited(LlmLogger.log(logEntry))` 这一行。即便 `unawaited` 不等待,日志队列的同步 `jsonEncode` 与 `_tail` Future 链注册也运行在 `return resp0` 之前的同一微任务批次里,与 `BridgeEvents.emit('done')` 派发竞争;`_tail` 串行化 + `_doWrite` 内 `flush:true` 写盘 + 清理目录三个 IO 操作,在慢盘或负载高的环境下会抢占主调用栈的微任务预算,反向阻塞事件派发。
- **回滚**:
  - 删 `lib/util/llm_logger.dart`、`test/llm_logger_test.dart`。
  - `_callOpenAI` / `_callAnthropic` 移除 `logEntry` 构造、`unawaited(LlmLogger.log(...))` 与 `startedAt` 计时;`LlmLogger` 相关 import 删除。
  - `brief.md` 中"LLM API 请求/响应落盘"一行改为"已下线"指针。
- **后续**: 如需重新引入该日志,需先把日志层与主调用栈解耦(例如把日志提交交给独立的 isolate 或完全脱离事件循环的 worker),再恢复 `unawaited` 调用点。

### 2026-09-10 · 桌面窗口尺寸记忆 / 对话页头部固定 / token 用量修复
- **窗口尺寸记忆**(`linux/runner/my_application.cc`):
  - 修复预存在的 C++ 编译错误:`g_signal_connect(window, "destroy", G_CALLBACK(+[](...){...}), ...)` 中 lambda 的逗号被 `G_CALLBACK` function-like 宏误判为多参数,改成自由函数 `OnDestroyFlush(GtkWindow*, gpointer)`。
  - 启动时 `ReadWindowPrefs` 读 `~/.xchat/window.json`(无则回退默认 1280x720),运行期 `configure-event` 通过 `SaveTimer` 防抖(500ms)写盘,`destroy` 阶段再 flush 一次,覆盖"运行期没拖窗口"的首启动保存问题。
- **桌面入口**(`lib/main.dart`):移除临时尝试引入的 `window_manager` 依赖与 Dart 端持久化(与 GTK 端重复且会写两份),保留最简 `main()`;持久化由 GTK 原生层负责,无 Dart 端开销、无闪烁。
- **依赖**(`pubspec.yaml`):不增加 `window_manager`,沿用 `webview_all` + GTK 原生方案。
- **对话页三段式布局**(`assets/web/js/pages/chat.js` + `assets/web/css/base.css`):
  - 新增 `.chat-page`(flex-column, height:100%, min-height:0);header 改为 `.chat-header`(sticky top + 底边线 + z-index:5),消息区改为 `.chat-msgs`(flex:1, overflow-y:auto, min-height:0),工具栏加 `.chat-toolbar`(sticky bottom + z-index:5)。
  - 解决"会话信息栏跟随滚动窗口滚走"——只在消息区内部滚动,头部/工具栏始终可见。
- **新消息 in/out 显示为 0 的修复**(`lib/agent/react_loop.dart` + `assets/web/js/pages/chat.js`):
  - `assistant_done` 事件 payload 增加 `input`/`output`/`cache` 三个字段(原先只有 `text` + `tool_calls`)。
  - 前端 `finalizeAssistant(text, toolCalls, usage)` 新增第三个参数;streaming 节点在收到 `assistant_done` 时用事件里的 usage 覆盖 `last.input/output/cache`,而不是 `last.input || 0`(后者因 streaming 节点本就为 0 而永远停留在 0)。
  - 兼容性:无 usage 字段的旧事件仍走 `last.input || 0` 兜底,旧 client 不受影响。
- **chat 页 token 用量补齐 cache**(`assets/web/js/pages/chat.js`):
  - 顶部累计 `<span id="usage">`:从 `ctx:X in:Y out:Z` 改为 `ctx:X in:Y out:Z cache:W`。
  - 单条 assistant 消息 meta:从 `in:X out:Y · model` 改为 `in:X out:Y cache:Z · model`(`cache` 默认 0,旧消息 XML 没有该属性时按 0 显示)。
- **CSS**(`assets/web/css/base.css`):新增 `.chat-page` / `.chat-header` / `.chat-msgs` / `.chat-toolbar` 一组样式,放在 markdown 样式块之前。

### 2026-09-10 · 优化新建会话流程 / 增加"以此建新会话"功能
- 重写 `assets/web/js/pages/wizard.js`:从 5 步向导(模板→Provider/Model→系统提示→Sandbox/工具→完成)改成**单页表单**:
  1. 模板卡片列表(选中高亮 .list-item.sel);
  2. Provider / Model 下拉 + 模板参数输入(从 `template.vars` 动态生成);
  3. 高级(默认折叠):sandbox、max_rounds、项目、标签。
  默认值:首个 provider / 首个 model / builtin:coder(或首个模板)/sandbox=`/tmp`/max_rounds=20。一键创建后跳转 `#/chat/<id>`。
- 新增后端 RPC `sessions.cloneMeta`(语义:复制目标会话的 sandbox/max_rounds/meta/system/tools/projectId/tags,**不**复制 messages/archive,生成新 id 后落盘):
  - `lib/session/session_ops.dart::cloneEmpty` 扩展:复制 `projectId` / `tags`,新增 `titleSuffix` 参数(默认 " (空副本)"),**不**自动写盘(由调用方负责)。
  - `lib/bridge/bridge_api.dart` 新增 `case 'sessions.cloneMeta'`,同步在 `kXchatJs` 嵌入 JS 中暴露 `cloneMeta`。
  - `assets/web/js/bridge.js` 同步暴露 `cloneMeta`。
- `assets/web/js/pages/session_list.js` 右键菜单新增 **"以此建新会话"**(数据动作为 `cloneMeta`),执行后直接 `Router.go('#/chat/<newId>')`。原"克隆"重命名"克隆(含历史)"以区分。
- `assets/web/css/base.css` 新增 `.list-item.sel`(选中态:左侧 accent 色条 + 背景)。
- `brief.md` 章节描述同步(wizard 5 步 → 单页,新增 "以此建新会话" 入口)。

### 2026-09-10 · 修复:5s 兜底误触发导致 user 消息双倍
- 修改 `assets/web/js/pages/chat.js::doSend` 5s 兜底判定:原实现只检查 `session.messages` 末尾消息,当 `appendChunk` 抢先创建了 streaming assistant 并占据末尾位置时,兜底误判为"没有 user",进而 `appendMessage` 再补一条 user → 前端出现"双倍 user"。
- 改为 `session.messages.some((m) => m.role === 'user' && m.text === t)`,在整个列表中查找,正确识别后端是否已经通过 `user_appended` 事件把对应 user 推过来。
- 不影响: 普通发送主流程(`doSend` 不预加 user,只信任 `user_appended`)、`appendChunk` 唯一 streaming 节点保证、`assistant_done` 终态全量重渲、Markdown 渲染、键位。

### 2026-09-10 · 输入键位 / Markdown 全量渲染(表格/Todo/KaTeX/Mermaid)
- 修改 `assets/web/js/pages/chat.js`:
  - 键位: `Enter` 发送,`Ctrl+Enter`(mac 上 `Cmd+Enter`)在 textarea 中插入换行(浏览器默认行为);输入框 placeholder 同步更新。
  - `renderMsg`: user/assistant/system 一律走 `Markdown.render`,用户消息也支持 markdown(表格、代码块、列表、KaTeX)。
- 新增 `assets/web/js/markdown_katex.js`: 纯前端 KaTeX 兼容 math 渲染(无外部库)。支持 $...$ / $$...$$、上下标 / \frac / \sqrt / \sum_{}^{} / \int_{}^{} / \lim_{} / \vec / \hat / \bar,矩阵(pmatrix / bmatrix / cases / matrix),希腊字母与常见符号(<=, >=, !=, ~=, ≡, ∈, ∉, ⊂, ∪, ∩, ∅, ∞, →, ⇒, ↔, ∂, ∇ 等)。
- 新增 `assets/web/js/markdown_mermaid.js`: 暂为占位,渲染 ```mermaid 代码块时输出"流程图(未安装 mermaid 库,显示源码)"+ 等宽原文;接口预留,后续引入 mermaid 库只需替换 `renderPlaceholder`。
- 重写 `assets/web/js/markdown.js`:
  - 抽取 <think> 块 + ```fence 代码块 + $$...$$/$...$ 数学块,各自渲染后回填。
  - 列表: 无序 / 有序 / 任务(`- [ ]` / `- [x]`),任务项带 disabled checkbox + line-through。
  - 表格: GFM pipe-table,支持 `:---:` / `:---` / `---:` 对齐。
  - 引用 / 水平线 / H1~H6 / 图片 / 链接 / 行内代码 / 粗体 / 斜体。
  - 行内数学: 占位机制,text 中先识别 $...$ / $$...$$ 转 \u0000MATH_N\u0000,行内最终用 `MarkdownKatex.renderInline` 替换。
- 修改 `assets/web/index.html`: 引入 `markdown_katex.js` / `markdown_mermaid.js` 在 `markdown.js` 之前(被依赖)。
- 修改 `assets/web/css/base.css`: 新增 md 元素样式(标题/引用/水平线/code/pre/列表/任务/图片/表格),任务列表 disabled checkbox + line-through;KaTeX(frac/sqrt/op sub+sup/matrix 风格);mermaid-placeholder。

### 2026-09-10 · 会话页消息重复 / 格式乱 / 思考过程块 / 关掉 nav 日志
- 修改 `assets/web/js/pages/chat.js`:
  - 修复用户消息双倍: `doSend` 不再前端预加 user,完全等后端 `user_appended` 事件;5s 超时降级补一条以防网络丢包;`user_appended` 处理去重(同文本不重复追加)。
  - 修复接收消息格式乱 + 双倍: 改写 `appendChunk`,只在最后一条 streaming assistant 不存在时 `insertAdjacentHTML` 一次,后续 chunk 全部走 `box.querySelector('.msg.assistant[data-streaming="1"] .msg-body').innerHTML = Markdown.render(last.text)`,不再触碰 firstChild。
  - `renderMsg` 把 markdown 渲染结果统一包在 `<div class="msg-body">` 里,避免和后续 meta 节点竞争 `firstChild`。
  - `assistant_done` 收尾时全量 `renderMessages`,清掉 streaming 标记。
- 修改 `assets/web/js/markdown.js`:
  - 新增 `<think>...</think>` 块抽取 + 可折叠 `<details class="think-block">` 渲染,默认折叠(summary 标"思考过程",body 斜体 muted);`extractThinkBlocks` 用占位符保护内部字符不被 markdown 规则破坏。
  - 新增 H1~H6、`<em>`、`<p>` 段落支持,链接/代码块/粗体规则改为先 escape 再 inline,杜绝 XSS。
- 修改 `assets/web/css/base.css`: 新增 `.think-block` 折叠样式(虚线左边框、斜体 muted summary、`<details>` 展开)。
- 修改 `lib/ui/webview_host.dart`: 删除 `onUrlChange` 订阅(每次 hashchange/资源请求都打 `Instance of 'UrlChange'`,噪音大于价值),保留 `onPageStarted / onPageFinished / onWebResourceError / onHttpError`。

### 2026-09-10 · 模型可选请求参数(thinking / reasoning_effort / temperature)UI
- 修改 `assets/web/js/pages/providers.js::editProvider.drawModels`:每个模型行追加 3 个控件:
  - **thinking** 下拉:`--` / `enabled` / `disabled` / `adaptive`,`--` 写入 `null`(由后端判断不传该字段)。
  - **reasoning_effort** 下拉:`--` / `max` / `xhigh` / `high` / `medium` / `low` / `minimal` / `none`,同样 `--` → `null`。
  - **temperature** 数值输入框:`min=0` `max=2` `step=0.05`,留空 → `null`(不传),非空夹紧到 `[0,2]`。
- 新增 `opt(value, label, current)` 模板函数,生成 `<option>` 并在 `current` 匹配时 `selected`。
- 统一 `row.querySelectorAll('input,select')` 监听:
  - `thinking` / `reasoning_effort` 回写 `m[f]`,`'--'` 写 `null`;
  - `temperature` 回写 `m.temperature`,留空 → `null`,否则 `clamp(0,2)`;
  - 其余字段保持原 `pricing` / `id` / `context` 行为。
- `addm` 新模型默认 `thinking:null, reasoning_effort:null, temperature:null`。
- 后端 `lib/agent/llm_client.dart` 已就绪:`_callOpenAI` 把 `reasoning_effort` 非 `'--'` 时透传,`thinking==enabled` 时降级为 `reasoning_effort=high`;`_callAnthropic` 把 `thinking==enabled` 转 `thinking:{type:'enabled',budget_tokens:4096}` 并禁 `temperature`,其它值不发送 `thinking` 块;`temperature` 范围 `clamp(0.0, 2.0)`。`ModelSpec.toJson/fromJson` 透传三字段。

### 2026-09-10 · Providers 模型参数行 label + 响应式布局

### 2025-XX-XX · 模板查看 / H5 弹窗 / 新建不持久化 / 主题切换
- 新增 `assets/web/js/modal.js`: `Modal.confirm / prompt / alert / view` 统一封装,WebView 中可用的弹窗(支持 Esc/Enter/遮罩点击,prompt 支持 choices 与 multiline)。
- 新增 `assets/web/js/theme.js`: `XchatTheme` 主题管理(light/dark/system),持久化到 `localStorage` + `config.ui.theme`,system 模式跟随系统。
- 新增 `assets/web/js/pages/settings.js` → `#/settings`: 主题切换 + 确认模式。
- `assets/web/index.html`: 引入 `modal.js` / `theme.js` / `settings.js`,合并两个重复的 DOMContentLoaded 脚本,DOMContentLoaded 时先调 `XchatTheme.apply()`。
- `assets/web/js/router.js`: topbar 加 [设置] 入口,render 时同步主题到 indicator。
- `assets/web/js/pages/templates.js` 重写: 每条加 [查看] 按钮(`Modal.view` 显示原始 XML,内置/用户都可用);新建模板进入编辑页不再写盘,只在内存里维护草稿,点 [保存] 才调 `xchat.templates.save`;离开未保存草稿时弹选择弹窗;所有弹窗走 `Modal.*`。
- `assets/web/js/pages/projects.js` / `session_list.js` / `chat.js`(doResend) / `providers.js`: 把所有原生 `confirm()`/`prompt()` 替换为 `Modal.*`。
- `lib/bridge/bridge_api.dart` `templates.save`: 允许 `id` 为空(自动生成 `user:<timestamp>`),与 H5 新建不持久化流程对齐。


## 9. 测试(`test/`)
- `blocklist_test.dart`、`path_guard_test.dart`、`session_io_test.dart`、`token_tracker_test.dart`、`widget_test.dart`。
- `llm_logger_test.dart` 已随日志功能回滚一并删除。

---

## 10. 关键约定 / 修复记录
- `ReactLoop._buildMessages` 严格保证 assistant 后紧跟 tool 结果(OpenAI 协议),孤立 tool 元素被丢弃。
- `Compressor` 触发判定优先用 `defaults.model_param.context_window`,回落到 provider 的 `model.context`。
- `PathGuard` 越界即抛 `PathEscapeError`,被 `ToolRegistry` 包成 `ERROR: path_escape` 文本结果。
- `shell` 工具有 layer_a 全模式拒绝、layer_b 需 confirm、yolo 下 layer_b 例外也会拒。
- WebView 端 `window.xchat` 已在 `assets/web/js/bridge.js` 同步注入,Dart 侧不再 `runJavaScript(kXchatJs)`,避免重复定义与 DOMContentLoaded 竞争。
- `Logger` 仅在 yolo 模式追加写(目前 `appendToolExec` 由调用方决定是否记录)。

---

## 📌 Agent 任务维护说明(本节为 prompt,执行新任务时请遵守)

> **当你在本项目上新增 / 修改 / 删除代码文件、类、函数或功能点时,必须把变更同步追加到本 `brief.md` 末尾,保持文档与代码同步。**
>
> **追加规则:**
> 1. 在文末 **"变更记录"** 一节下按时间倒序追加,每条写明: 日期 / 改动范围(文件 + 类/函数) / 新增或修改的功能点。
> 2. 新增文件/类: 在对应顶层章节(入口/桥接/Agent/会话/配置/工具/Util/前端)补一条记录,并在末尾变更记录里写摘要。
> 3. 删除文件/类: 把对应章节的描述标记为 `~~删除于 YYYY-MM-DD~~`,并在变更记录里写一句原因。
> 4. 功能点重命名或合并: 同步改章节标题与变更记录。
> 5. 文末的 "📌 Agent 任务维护说明" 段不要删除,后续 Agent 继续追加。
>
> **格式示例(放在文末):**
>
> ```markdown
> ## 变更记录
>
> ### 2025-XX-XX
> - 新增 `lib/agent/plan_mode.dart`:`PlanMode` 计划模式,把工具调用前置为 plan 节点(由 `ReactLoop` 注入 `_pendingPlan`)→ 用户确认后执行。
> - 修改 `lib/bridge/bridge_api.dart::BridgeApi.handle`: 新增 `sessions.export` / `sessions.import` 两个 RPC,导出到 `~/.xchat/exports/<id>.json`。
> - 删除 `lib/util/legacy_xml.dart`(被 `XmlReader` 取代)。
> ```
