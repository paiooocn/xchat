# XChat 架构速览（索引层）

> 本文只写**结构与不变量**。设计动机见 `DESIGN.md`，功能清单见 `FEATURES.md`。
> 文件级事实见 `MAP.yaml`，职责与风险见 `ANNOTATIONS.yaml`。

## 1. 分层与依赖方向

```
  ui.pages / ui.widgets / ui.theme        Flutter 界面
          │
  state   AppState · ApprovalCenter        全局状态 / 跨会话审批队列
          │
  session SessionController · SessionOps    单会话运行时（多会话并行）
          │
  agent   AgentEngine                       ReAct 主循环
          │                    │
  llm     OutboundAdapter · LlmFactory      出站适配 / provider 工厂
          │                    │
  agent.tools  BuiltinTools · PathGuard · WebView     pkg.llm_api（vendor LLM 客户端）
          │
  data    Session/Template/Config/Project/IndexRepository
          │
  data.xml  SessionXml · TemplateXml · ProjectXml · XmlOut
          │
  models  会话/消息/配置/provider/模板/项目（纯数据，无 Flutter 依赖）
          │
  core    AppPaths · app_version · json_utils · python_runtime
```

依赖方向自上而下。**唯一的反向引用**：`core` 的两个文件用了模型类型
（`python_runtime.dart`→`ProxyConfig`、`window_prefs.dart`→`AppConfig`），
`models` 侧也有文件用到 `core` 的 JSON 工具 —— 这是底层良性环，不要再往上扩散。

## 2. 启动流程（`lib/main.dart`）

```
ensureInitialized
  → AppPaths.requestSharedAccess()   Android 申请共享存储权限
  → AppPaths.init()                  解析数据根目录（失败必须降级，不能抛）
  → 构造 IndexRepository + 4 个 Repository + AppState
  → state.load()                     读 config.json + index.json（try/catch 兜底）
  → 桌面端：恢复窗口尺寸（先 best-effort，首帧后再幂等重放一次）
  → runApp(Provider<AppState> → XChatApp)
```

**不变量**：`runApp` 之前任何异常都必须被吞掉并降级 —— 数据根目录坏了也要让用户进设置页换目录。

## 3. 一次 turn 的数据流

```
UI 发消息
  → SessionController.send()
  → AgentEngine.run(userText, attachments)
      ├ 写入 user 消息（附件落进 <sandbox>/attachments/）并持久化
      ├ BuiltinTools.build(...) → ToolRegistry（按会话开关裁剪工具）
      ├ createProvider(...)     → llm_api provider
      └ while 循环：
          ├ 出站：OutboundAdapter 把 Session.messages → llm_api ChatMessage
          │        （思考回发 + tool 协议修复）
          ├ 流式：ChatEvent → AgentEvent → UI（思考块/文本/工具调用块）
          ├ 工具调用 → 执行 → 结果回写为 tool 消息 → 下一轮
          └ 预算检查：累计轮次 ≥ toolCallsLimit → 追加一条续判 user 消息
  → 落盘：SessionRepository → XML（原子写）
  → 索引：IndexRepository 增量更新 index.json
```

## 4. 落盘布局

```
<root>/
  config.json                 全局配置
  sessions/<uuid>.xml         会话（根元素 chat，sandbox 属性记录工作目录）
  templates/                  会话模板
  scripts/<id>.json           页面提取脚本
  projects/                   项目文件与工作目录
  logs/
  sandboxs/                   每会话工作目录
```

数据根目录：桌面 `~/Documents/XChat`；Android `/sdcard/com.yimo.xchat/data`（需共享存储权限）。

## 5. 跨层不变量（改代码前先确认自己没破坏）

1. **序列化只在 `data.xml`**：`models` 里不得出现任何 XML/JSON 拼装逻辑。
2. **UI 不直接碰文件系统**：一律经 `data` 层的 repository。
3. **全局状态只有一个**：`AppState`（`ChangeNotifier`），会话级状态在 `SessionController`。
4. **工具路径必须过 `PathGuard`**：`resolve` 拦 `..`，涉及真实读写用 `resolveReal` 追符号链接。
5. **出站消息必须满足 tool 协议**：`assistant.tool_calls` 后恰好一条对应 `tool` 消息。
6. **思考内容必须回发**：`reasoning_content` 与 `<think>` 两种形态都要发给模型。
7. **`index.json` 是缓存，磁盘是事实**：加载时校验，不一致就透明重建。
8. **controller 生命周期长于面板**：切换会话不 dispose，否则并行会话会被打断。
9. **用量口径固定**：单次写 assistant，累计写 system（含 context）。
10. **新字段必须能读旧文件**：会话 XML 是长期存档，格式只能加不能改语义。
11. **`task_id` 是显示维度，不是上下文维度**：任务式会话（`kind="task"`）里消息带
    `task_id`，但出站历史永远是整个会话（`buildChatMessages(session)`，方案 B）；
    `SessionOps.*OnlyTaskId` 只用于编辑/删除/滚动定位这类「改数据」的路径，
    而删改必须限定在同一任务的范围内（否则会误删别的任务的对话）。
12. **一手消息一手 taskId**：一次 turn 产生的 user/assistant/tool 消息由
    `AgentEngine` 统一打标（构造参数 `taskId`），别在别处补。
