# XChat

基于 Flutter 的跨平台 LLM Agent GUI（Android / iOS / macOS / Windows / Linux）。

- **Agent**：ReAct 模式，工具调用有次数上限；达到上限后自动追加一条对话由模型自判是否继续。
- **API**：OpenAI 兼容，支持 `reasoning_content`（deepseek/kimi/glm/mimo）与 `<think>`（minimax）两种思考模式的显示与**回发**。
- **持久化**：`Documents/XChat/`，会话为 XML（根元素 `chat`，`sandbox` 属性记录目录，文件名为会话 UUID），文本一律 CDATA。
- **Token 统计**：单次写入 `assistant` 的 `input/output/cache`；累计写入 `system` 的 `input/output/cache` 与 `context`。
- **会话功能**：创建向导、会话模板、外部/内置编辑器打开、最近一次 user 消息编辑即重发、克隆到首个 user。

设计细节见 [`DESIGN.md`](DESIGN.md)。

## 目录布局

```
Documents/XChat/
  config.json     应用配置（providers、默认参数、编辑器、主题…）
  sessions/       会话 XML（默认 sandbox，<uuid>.xml）
  templates/      会话模板
  logs/
```

## 开发

```bash
flutter pub get
flutter test           # XML 往返 / 会话操作单测
flutter run            # 或 flutter build apk / linux / macos / windows
```

LLM 客户端为仓库内 vendor 的 `packages/llm_api`（provider-agnostic OpenAI 兼容流式客户端）。

## 结构

- `lib/models` — 会话/消息/参数/模板/provider/配置模型
- `lib/data/xml` — 会话与模板的 XML 编解码（CDATA 手写 writer，避免转义与缩进污染）
- `lib/data` — 会话/模板/配置仓库（原子写盘）
- `lib/llm` — provider 工厂与思考回发适配（reasoning_content ↔ think_tag）
- `lib/agent` — ReAct 引擎、事件、内置工具（含沙箱路径守卫、web_search/http_fetch）
- `lib/session` — 会话操作与运行时控制器
- `lib/ui` — 页面与组件（自适应宽窄屏）
- `lib/state` — 全局 AppState
