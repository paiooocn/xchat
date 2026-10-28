# XChat 记忆索引 · 入口

本目录是本仓库的**记忆索引**：让一个新会话（人或 AI）不必读完 77KB 的设计文档，
也能知道 **要改的东西在哪 · 有哪些不能碰的坑 · 上次做到哪**。

> 索引是**路由**，不是内容。
> 「为什么这么设计」→ `DESIGN.md`；「代码在哪」→ `MAP.yaml`；「踩过什么坑」→ `GOTCHAS.md`。
> 索引不复制 DESIGN.md 的段落，只引用章节号。

---

## 1. 目录

| 文件 | 维护方式 | 内容 | 什么时候读 |
|---|---|---|---|
| `README.md` | 手写 | 本文件：入口、路由表、维护规则 | **每次会话第一个读** |
| `STATE.md` | 手写 | 上次做到哪、下一步、待验证 | **每次会话第二个读** |
| `ARCHITECTURE.md` | 手写 | 分层、数据流、跨层不变量 | 动结构或数据流前 |
| `GOTCHAS.md` | 手写 | 雷区与隐性契约 | 动 `risk: high` 的模块前 |
| `MAP.yaml` | **生成** | 文件 / 顶层符号 / 模块依赖 / 测试清单 | 定位代码、评估影响面 |
| `ANNOTATIONS.yaml` | 手写 | 模块职责、改动风险、**功能→文件映射** | 规划改动范围 |

刷新事实层：

```sh
dart run tool/gen_memory_index.dart          # 重新生成 MAP.yaml
dart run tool/gen_memory_index.dart --check  # 校验是否与代码一致（过期则退出码 1）
```

---

## 2. 新会话启动协议（给 AI）

> **本节是协议的权威出处**（全仓库仅此一份），别处不复制副本。
> `PROMPT.md` 里有可直接粘贴的**注入块**；在 XChat 内使用建议把它存进会话模板的系统提示词。


1. 读 `README.md`（本文件）—— 知道索引怎么用。
2. 读 `STATE.md` —— 知道上一轮做到哪、有没有半成品。
3. 按任务查 `ANNOTATIONS.yaml` 的 `features` —— 确定**要动的文件集合**；
   用 `MAP.yaml` 找符号与依赖，判断影响面。
4. 命中 `risk: high` 的模块 → 读 `GOTCHAS.md` 对应条目 + `DESIGN.md` 引用章节。
5. 动结构 → 读 `ARCHITECTURE.md` 的跨层契约。

**红线**

- 索引是路由不是内容：它告诉你"在哪"，行为与实现以源码为准
- 引用代码位置用「文件路径 + 符号名」或「DESIGN.md §章节号」，**不写行号**
- 不在索引里复制 DESIGN.md 的段落，也不擅自改它的设计结论

## 3. 路由表：我想改 X → 去哪

| 任务 | 先读 | 主要文件（详见 `ANNOTATIONS.yaml`） |
|---|---|---|
| 会话存盘格式 / 消息结构 | `GOTCHAS.md` §1 | `lib/data/xml/*`、`lib/models/session*.dart` |
| 思考内容显示或回发 | `GOTCHAS.md` §4 | `lib/llm/outbound_adapter.dart` |
| 工具调用协议报错 | `GOTCHAS.md` §5 | `lib/llm/outbound_adapter.dart` |
| ReAct 循环 / 工具预算 | `DESIGN.md` §9 | `lib/agent/agent_engine.dart` |
| 新增或修改 Agent 工具 | `GOTCHAS.md` §3 | `lib/agent/tools/builtin_tools.dart` |
| 沙箱与路径安全 | `GOTCHAS.md` §3 | `lib/agent/tools/path_guard.dart` |
| shell 命令分级 | `GOTCHAS.md` §6 | `lib/models/shell_policy.dart`、`lib/models/shell_exec.dart` |
| 搜索与页面提取 | `DESIGN.md` §19 | `lib/agent/tools/webview_*.dart`、`script_registry.dart` |
| 内置 Python / pip | `docs/PYTHON_RUNTIME_PLAN.md` | `lib/core/python_runtime.dart`、`python_packages.dart` |
| Provider 与代理 | `DESIGN.md` §13 | `lib/ui/pages/providers_page.dart`、`lib/llm/llm_factory.dart` |
| 模型目录同步 | `DESIGN.md` §17 | `lib/data/models_dev_repository.dart` |
| 页面 / 布局 | — | `lib/ui/pages/*`（`home_page.dart` 近 3000 行，先 grep 再改） |
| 消息渲染 / 公式 | `GOTCHAS.md` §8 | `lib/ui/widgets/markdown_view.dart`、`math_support.dart` |
| 全局配置项 | `FEATURES.md` §8 | `lib/models/app_config.dart`、`lib/data/config_repository.dart` |
| 会话列表 / 索引 | `GOTCHAS.md` §7 | `lib/data/index_repository.dart`、`lib/models/catalog_index.dart` |
| 多会话并行 / 审批 | `GOTCHAS.md` §9 | `lib/session/session_controller.dart`、`lib/state/approval_center.dart` |
| 构建 / 发布 / 平台差异 | `FEATURES.md` §10 | `android/`、`ios/`、`linux/`、`windows/`、`macos/` |

---

## 4. 维护规则

**只存一处**

| 知识 | 唯一出处 |
|---|---|
| 文件、符号、依赖关系 | `MAP.yaml`（生成） |
| 模块职责、风险、功能→文件映射 | `ANNOTATIONS.yaml` |
| 分层、数据流、不变量 | `ARCHITECTURE.md` |
| 坑、易踩的隐式契约 | `GOTCHAS.md` |
| 设计动机与细节 | `DESIGN.md`（**不复制到索引**） |
| 进度与下一步 | `STATE.md` |

**引用规范**

- 用 `文件路径 + 符号名`，例如 `lib/agent/agent_engine.dart` 的 `AgentEngine`。
- 用 `DESIGN.md §9.2` 这样的章节号。
- **禁止写行号**——代码一改就失效。

**收尾流程（改完代码后）**

1. 跑 `dart run tool/gen_memory_index.dart` 刷新 `MAP.yaml`。
2. 若新增/删除/移动了文件、或模块职责变了 → 同步 `ANNOTATIONS.yaml` 的 `modules`。
3. 若某功能牵连的文件变了 → 同步 `ANNOTATIONS.yaml` 的 `features[].files`。
4. 更新 `STATE.md`：做了什么、下一步、待验证项。

---

## 5. 为什么不用 XML 存索引

同信息量实测（12 模块 × 7 字段，cl100k 分词）：

| 格式 | tokens | 相对 MD |
|---|---|---|
| Markdown | 1285 | ×1.00 |
| YAML | 1293 | ×1.01 |
| XML（缩进） | 1809 | ×1.41 |

差值**全部来自标签本身**（剥掉标记后两种格式的正文 token 数一致）。
而且 `grep` 不支持 XPath，真要 XPath 得先造工具链 —— 收益远小于成本。
所以：**MD 承载人的知识，YAML 承载机读事实**。
