# XChat 桌面版内置 Python 3 · 实施方案

> 目标：桌面端（Linux / Windows / macOS）自带一个可用的 Python 3 运行时，
> 让 Agent 在未安装 Python 的机器上也能直接跑脚本（数据处理、生成文件、调用库），
> 并让用户能装/卸第三方包。

---

## 0. 范围与边界

**做**：桌面三平台的 Python 3 运行时（解释器 + pip + 包目录）落地、定位、暴露给 Agent、审批与打包。
**不做（本期）**：Android / iOS 内置 Python（体积与合规成本高）；把网页解析脚本（`assets/scripts/*.json`，JS）改写成 Python（另立需求，见 §9）。

---

## 1. 现状（代码依据）

| 事实 | 位置 |
|---|---|
| `shell` 工具用 `Process.start` 拉起 shell，工作目录=沙箱 | `lib/agent/tools/builtin_tools.dart`（`_ShellTool`） |
| shell 可执行文件/参数模板由用户配置，落 `config.json` | `lib/models/shell_exec.dart`、`lib/models/app_config.dart` |
| shell 命令按 1级/2级/F级 名单分类审批，基础等级锁定 3 | `lib/agent/agent_engine.dart`、`lib/models/shell_policy.dart` |
| 已有"外部可执行文件探测"先例（Chromium） | `lib/agent/tools/browser_session.dart::_locateBrowser` |
| 桌面打包脚本：deb（`dist/build_deb.sh`）、windows zip（`dist/build_windows.ps1`） | `dist/` |
| 数据根目录 `~/Documents/XChat`，可放 runtime 子目录 | `lib/core/app_paths.dart` |

结论：**不需要新造执行器**，只需补一个"解释器定位 + 环境构造"层，再把 `shell` 与新工具接到它上面。

---

## 2. 运行时来源与选型

选用 **python-build-standalone**（CPython 官方构建的独立可重定位发行版，PSF-2.0 兼容）：

- 优势：单目录、免安装、免系统依赖、可重定位、Linux/Windows/macOS 齐备、体积可控。
- 版本：CPython **3.12.x**（3.13 亦可，取决于发行版可用性），长期支持。
- 变体：`install_only`（最小可用集），裁剪 `test/`、`tk/`、`tcl/`、`idlelib/`；保留 `pip`。
- 体积：裁剪后压缩 ~15MB / 解压 ~60MB（Linux x64 实测量级）。

**备选（需决策）**：Linux 走 `Depends: python3` 依赖系统包（deb 体积不变、但要求用户装包，且版本不可控）；Windows 用官方 embeddable zip（缺 pip、缺 Tcl，能力弱）。→ 不推荐，能力不一致。

下载与校验：`tool/python_manifest.json` 记录 `version / triple / url / sha256 / size`，
`tool/fetch_python.sh` 负责下载 + sha256 校验 + 解压到 `third_party/python/<triple>/`。

---

## 3. 落地分层（Tier）与解析顺序

**目录约定：`<AppDir>/runtime/python/`**，`AppDir = dirname(Platform.resolvedExecutable)`

| 平台 | 落地路径 | 打包来源 |
|---|---|---|
| Linux (deb) | `/usr/lib/xchat/runtime/python/` | `dist/build_deb.sh` 拷贝 |
| Linux (tar/本地) | `build/linux/x64/release/bundle/runtime/python/` | `flutter build linux` 产物 |
| Windows (zip) | `<Release>/runtime/python/`（zip 内 `runtime/python/`） | `dist/build_windows.ps1` 拷贝 |
| macOS (app) | `XChat.app/Contents/Resources/runtime/python/` | `dist/build_macos.sh` 拷贝 + `codesign --deep` |
| Tier 2 开发态 | `<repo>/third_party/python/`（内含 `bin/`，供 `flutter run`） | `tool/fetch_python.sh` 拉取 |
| Tier 3 系统 | PATH 上的 `python3` / `python` | — |

目录内部保持发行包原样（不做裁剪重排，便于校验与升级）：

```
runtime/python/                  # POSIX
  bin/python3.12 -> python3.12  (符号链接需保留，cp -a)
  bin/python3    -> python3.12
  lib/python3.12/  include/  share/
runtime/python/                  # Windows
  python.exe  python3.dll  DLLs/  Lib/
```

**只读/可写分层（重要）**
- 解释器本体放**应用包目录**：随应用升级整体替换，卸载即清理。
- pip 装的包、用户脚本、缓存放**数据根目录**：`<AppPaths.root>/runtime/pypkgs/`
  （即 `~/Documents/XChat/runtime/pypkgs/`），`PYTHONPATH` 指向它。
  原因：Windows 装到 `Program Files` 后应用包目录只读，Linux 的 `/usr/lib` 属 root，
  用户数据不能落在那里；数据根目录已有 `ensureDirs`/迁移机制。
- 环境变量固定注入：`PYTHONHOME=<runtime>`、`PYTHONPATH=<DataRoot>/runtime/pypkgs[:用户自定义]`、
  `PYTHONNOUSERSITE=1`（屏蔽用户 site-packages，保证行为可复现）。
- 调试覆盖：环境变量 `XCHAT_PYTHON_HOME` 优先于以上全部路径。

解析函数（`lib/core/python_runtime.dart`）返回 `PythonRuntime?`：

```
config.pythonInterpreter == 'custom'  → config.pythonPath（存在才用）
== 'builtin'                          → 只认 Tier 1/2
== 'system'                           → 只认 Tier 3
== 'auto'（默认）                     → Tier 1/2 → Tier 3
```

返回对象携带：`executable`（Tier1 用 `bin/python3` / `python.exe`）、
`home`（PYTHONHOME）、`packagesDir`（PYTHONPATH）、`env`（构造好的子进程环境）。

**Windows 注意**：不能只拷 `python.exe`，需整目录（`python311.dll`、`Lib/`、`DLLs/`）。
**Linux 注意**：`bin/python3` 多为符号链接 → 必须保留 symlink（`cp -a`）或直接指向 `bin/python3.12`。
**macOS 注意**：arm64/x64 分架构分发（或 universal2 构建），并需随应用 `codesign --deep` 签名。

---

## 4. 暴露给 Agent 的两条路径

### 4.1 路径 A（最小改动，建议先落）：shell PATH 注入

在 `_ShellTool.call` 启动子进程时，把 runtime 的 `bin` 目录前置到 `PATH`：

```dart
process = await Process.start(
  resolved.executable,
  resolved.argumentsFor(command),
  workingDirectory: sandbox,
  environment: runtime?.childEnv ?? null,   // PATH 前置 + PYTHONHOME + PYTHONPATH
);
```

效果：模型写 `python3 analyze.py` 即可运行，且**自动继承 shell 的 1/2/F 级审批策略**（`pip3?` 已在 1 级名单），无需新增安全面。

### 4.2 路径 B：新增 `python_run` 工具

参数：`script`（沙箱内 .py 路径）、`args[]`、`stdin`、`timeout_seconds`。
行为：直接 `Process.start(interpreter, [script, ...args], workingDirectory: sandbox, environment: ...)`，
返回 stdout/stderr/exit code（复用 `decodeShellOutput`），支持 turn 取消时 kill 子进程。
优点：跨平台一致、免 shell 引号转义、参数以数组传递（避免 §shell_exec 里那套转义坑）。

**建议**：A 与 B 都做——A 满足"随手 `python3 xxx.py`"，B 满足"稳定调用 + 结构化参数"。

---

## 5. 第三方包（pip）管理

- 安装位置：`<root>/runtime/pypkgs`（数据根目录，非应用包内，避免只读/升级丢包）。
- 安装方式：`python -m pip install --target <root>/runtime/pypkgs <pkg>`；运行时 `PYTHONPATH=<root>/runtime/pypkgs`。
- 镜像源：默认国内镜像 `https://pypi.tuna.tsinghua.edu.cn/simple`（可配置）。
- 离线兜底：`assets/pypi-wheels/` 放白名单 wheel（如 pandas/numpy 的常见平台包），无网时 `--no-index --find-links` 安装。
- UI（工具管理页「Python 运行时」区）：已安装包列表、pip 安装/卸载（走审批）、镜像源编辑。
- 包清单持久化在 `config.json`（`python_packages`）便于展示，实际以目录扫描为准。

---

## 6. 安全与审批

- 运行时以**当前用户权限**执行，cwd 固定为会话沙箱；不额外提权。
- `python_run` 工具：基础审批等级锁定 **3**（与 shell 一致，未命中名单也需确认）；
  命令行文本（`python script.py --x`）复用 `classifyShellCommand` 的 1级/2级/F级 名单，
  另加 `python_denied_commands`（默认空，避免误伤；预置 `pip install` 属 2 级、`rm -rf` 类保持 F 级）。
- 脚本内行为无法静态审查 → 依赖 3 级审批 + 沙箱 cwd + 现有路径守卫。
- 明确不做：不做 Python 沙箱隔离（无 seccomp/无容器），在文档中写清"等同 shell 权限"。

---

## 7. 配置项（`config.json` → `AppConfig`）

| 键 | 类型 | 默认 | 说明 |
|---|---|---|---|
| `python_interpreter` | string | `auto` | `auto` / `builtin` / `system` / `custom` |
| `python_path` | string | `''` | custom 模式下的解释器绝对路径 |
| `python_extra_paths` | string[] | `[]` | 追加到 PYTHONPATH 的目录 |
| `python_pip_index` | string | 清华镜像 | pip 索引地址 |
| `python_timeout_seconds` | int | `120` | python_run 默认超时 |
| `python_packages` | string[] | `[]` | 已安装包（展示用缓存） |

---

## 8. 代码改动清单（文件级）

**新增**
- `lib/core/python_runtime.dart` — 解释器定位 / 环境构造 / 版本探测 / pip target 管理。
- `lib/agent/tools/python_tool.dart` — `python_run` 工具实现。
- `tool/python_manifest.json` + `tool/fetch_python.sh` — 运行时下载与校验。
- `test/python_runtime_test.dart` — 解析顺序与环境构造单测。

**修改**
- `lib/core/app_paths.dart` — 新增 `runtimeDir`、`pythonPackagesDir`。
- `lib/agent/tools/builtin_tools.dart` — 工具目录加 `python_run`；`build()` 增加 `pythonRuntime` 参数；`_ShellTool` 注入 PATH。
- `lib/agent/agent_engine.dart` — `python_run` 的审批等级与名单分类（base=3）。
- `lib/models/app_config.dart` — 上表配置项 + 默认值 + 序列化/反序列化。
- `lib/ui/pages/tools_page.dart` — 「Python 运行时」设置区（来源/路径/版本/包/pip 操作）。
- `lib/ui/pages/session_wizard_page.dart` — 工具清单加入 `python_run`（默认不开）。
- `dist/build_deb.sh` — 打包期把 `third_party/python/linux-x86_64/` 拷到 `/usr/lib/xchat/runtime/python/`。
- `dist/build_windows.ps1` — 拷到 `<bundle>/runtime/python/`。
- `dist/build_macos.sh`（新建）— 拷到 `XChat.app/Contents/Resources/runtime/python/` 并 `codesign --deep`。
- `pubspec.yaml` — （可选）`assets/pypi-wheels/` 离线 wheel 声明。
- `DESIGN.md`（新增 §20）/ `FEATURES.md` — 文档同步。

---

## 9. 里程碑与验收

| 阶段 | 内容 | 产出 |
|---|---|---|
| M1 | `python_runtime.dart` + 配置项 + 单测 | 能在本机定位到解释器并打印版本 |
| M2 | `python_run` 工具 + shell PATH 注入 + 审批接入 | Agent 可跑脚本，走审批 |
| M3 | 下载脚本 + 三平台打包集成 + sha256 校验 | deb/zip/app 内含 runtime |
| M4 | 工具管理 UI（来源/版本/pip 包管理） | 用户可自管解释器与包 |
| M5 | 文档 + 冒烟测试（干净机器验证） | 验收通过 |

**验收标准**
1. 全新虚拟机（无任何 Python）安装 deb → 工具管理页显示"内置 Python 3.12.x"，Agent 能 `python3 -V`、能跑 CSV 处理脚本。
2. Agent 调用 `python_run` 需审批；命中 F 级名单被拒。
3. `pip install requests` 后脚本可 import；卸载后不可用。
4. 系统已装 Python 时，`auto` 模式仍优先用内置（行为稳定），`system` 模式可切回系统解释器。
5. Windows/macOS 包内 runtime 可执行，Windows Defender 无阻断告警（需签名或说明文件）。

---

## 10. 风险与对策

| 风险 | 影响 | 对策 |
|---|---|---|
| 体积膨胀（deb 19MB → ~60MB+） | 安装包变大 | 决策点 D2：改为"首次使用时按需下载 + sha256 校验"，或提供 `xchat-lite` 包 |
| Windows 未签名 `python.exe` | SmartScreen / 杀软误报 | 随包附来源与校验说明；或用 `uv` 风格按需下载 |
| macOS 公证 | 签名失败导致无法分发 | `codesign --deep` 签 runtime；Apple Silicon 与 Intel 分别分发 |
| 许可证 | 合规 | PSF-2.0 兼容；应用内列出第三方组件与许可证 |
| 版本安全更新滞后 | CVE 风险 | manifest 记录版本 + sha256，升级只需改 manifest + 重新打包 |
| shell 与 python 双通道绕过名单 | 审批面扩大 | 明确 python_run 走 3 级审批；PATH 注入只解决"能不能跑"，不放宽审批 |

**待确认决策点**
- **D1** 解释器来源：统一内置（python-build-standalone）／ 仅 Linux 依赖系统包？→ 建议统一内置。
- **D2** 交付方式：随包内置（体积换体验）／ 首次使用按需下载（体积换下载）？→ 建议 A 随包 + 预留按需下载开关。
- **D3** 是否同时做 `python_run` 工具，还是仅做 PATH 注入？→ 建议两者都做（A 先、B 后）。
- **D4** 是否需要 `pip` 离线 wheel 兜底（体积 +~30MB）？→ 建议首发只做在线安装。

---

## 11. 已实现（第一阶段：运行时准备 + pip 管理）

### 11.1 运行时下载（uv）
- `tool/fetch_python.sh`：用 **uv** 下载 python-build-standalone 发行版（可重定位、自带 stdlib/pip）到
  `third_party/python/`，目录形如 `cpython-3.12.13-linux-x86_64-gnu/`（Windows 为 `cpython-3.12.x-windows-x86_64-msvc/`）。
  - 国内加速：`UV_PYTHON_INSTALL_MIRROR=https://ghproxy.net/https://github.com/astral-sh/python-build-standalone/releases/download bash tool/fetch_python.sh`
  - 实测：uv 0.11.28 拉取 cpython-3.12.13-linux-x86_64-gnu（32.6 MiB），`bin/python3` 可直接执行，版本 3.12.13。
- 打包注入：`dist/build_deb.sh` → `/usr/lib/xchat/runtime/python`；`dist/build_windows.ps1` → `<Bundle>\runtime\python`。

### 11.2 代码
- `lib/core/python_runtime.dart`：解释器定位（`XCHAT_PYTHON_HOME` → `<AppDir>/runtime/python` → `third_party/python/*` → 系统 PATH）、
  子进程环境构造（PATH 前置、PYTHONPATH、PYTHONNOUSERSITE、代理、pip 镜像）。
- `lib/core/python_packages.dart`：解析 `*.dist-info`（METADATA/RECORD）、内置常见库中文说明词表、
  按 RECORD 卸载（只删包目录内文件）。
- `lib/agent/tools/builtin_tools.dart` / `lib/agent/agent_engine.dart`：`shell` 工具注入上述环境 →
  Agent 可直接 `python3 x.py`、`pip install x`（走镜像链与应用代理）。
- `lib/ui/pages/pip_packages_page.dart`：顶栏「更多 → pip 库管理」页（解释器来源/版本/路径、镜像链编辑、
  已安装库列表 + 中文说明 + 卸载、按镜像链顺序安装）。
- 配置项（`config.json`）：`python_source` / `python_path` / `python_extra_paths` / `pip_index_urls` / `python_timeout_seconds`。

### 11.3 镜像与代理
- 镜像链默认 **清华 → 阿里 → 官方**：`PIP_INDEX_URL`=首个，`PIP_EXTRA_INDEX_URL`=其余（pip 天然回退）；
  页面里的安装按钮则按顺序逐个 `-i <mirror>` 显式尝试。
- 代理：应用的 `ProxyConfig` 写入子进程 `HTTP_PROXY` / `HTTPS_PROXY` / `NO_PROXY`，python 与 pip 均生效。
- pip 缓存目录：`<数据根>/runtime/pip-cache`，不污染 `$HOME`。
