# 任务式会话改进方案（待拍板）

三项需求：

1. 创建任务式会话时，**任务项不再是必需的**。
2. 任务勾选「完成」后，**该任务对话的发送按钮锁定**；取消「完成」才恢复。
3. 新增**自动流式执行**：点「自动执行」后按顺序逐个跑任务。

现状（源码核对结果）：任务项只在两处参与逻辑 —— `TaskItem.done`（纯手工开关）
与 `Session.taskMessages/taskHasReply`（显示分组）；出站历史始终是整个会话
（`ANNOTATIONS.yaml` `task_sessions` 契约，本次不改）。

---

## 1. 需求一：任务项不必在创建时就有

**现状**：`lib/ui/pages/session_wizard_page.dart` 的 `_SessionWizardPageState._finish`
里有一段校验：`_kind == SessionKind.task && _draftTasks.isEmpty` → SnackBar 拦下。

**改法**：删掉这段校验（`_finish` 直通），并同步文案/注释：

- `session_wizard_page.dart` 里 `_kind` 的注释与 `_SectionLabel('会话模式')` 的 hint：
  改为「任务式会话打开后先显示任务列表，可先建空列表，进入后再新增任务项」。
- `_TaskDraftSection` 标题下的说明补一句「留空也能创建，进入会话后再加任务」。
- 存储层无需改动：`session_xml.dart` 对 `kind == task` 恒写 `<tasks>`（空时写
  `<tasks/>`），`SessionXml.decode` 读回空列表；`SessionKind.task` + 空 tasks 已是
  合法往返状态。
- `TaskListView` 空态已存在（`还没有任务项…`），补一颗「新增任务」按钮，避免空态
  只有文字（列表头已有两个按钮，空态里再放一个更直接）。

**影响面**：仅向导页 + 任务列表空态。无迁移、无格式变更。

---

## 2. 需求二：已完成任务锁定发送

**判定**：`SessionChatPanel` 里已有 `widget.taskId`，取
`session.taskById(widget.taskId)?.done` 得到 `taskDone`。

**改法（三层，缺一不可）**

1. `lib/ui/widgets/input_area.dart` 新增两个参数：
   - `bool sendLocked = false`：`_canSend` 加 `!widget.sendLocked`；
     `_send()` 开头早退；桌面端 Enter 的 `_SendIntent` 也走 `_send()`，天然被拦。
   - `String? lockedHint`：非空时替换输入框 hint（默认文案
     `任务已完成：勾回「完成」后可继续发送`）。
   - 发送键 tooltip 在锁定时改为同一句提示；附件按钮、模式/联网开关仍可用
     （只锁「发出去」这一个动作，不做整块灰掉）。
2. `home_page.dart` 的 `SessionChatPanel`：计算 `taskDone` →
   `InputArea(sendLocked: taskDone, lockedHint: ...)`；同时
   - `controller.error != null` 的「继续生成」按钮在 `taskDone` 时不再显示
     （否则绕过锁）；
   - `_maybeStartTask()`（打开新任务时的「开始这个任务？」弹窗）在
     `task.done` 时直接返回。
3. 解锁路径不变：`TaskChatHeader` 的「完成」勾选框与 `TaskListView` 行首勾选框都已
   直接写 `task.done` + `persistSession`，取消勾选后面板重建即恢复可发送。

**不做**：不锁编辑/删除历史消息，不锁「压缩会话」以外的其它菜单动作（保持最小改动）。

---

## 3. 需求三：自动流式执行

### 3.1 状态机放哪

自动执行必须**跨面板存活**（切会话、进任务对话、移动端压栈都不该断），所以放在
`lib/session/session_controller.dart`（`SessionController` 已随会话常驻，
`AppState.controllerFor` 持有），不放在 widget 里。

新增成员：

```dart
bool get autoRunning;
String? get autoCurrentTaskId;   // 轮次之间也有值（用于列表高亮）
int get autoTotal;               // 队列长度
int get autoDoneCount;           // 已跑完的项数

/// 依次执行 [taskIds]；markDone 为真时每项成功后自动勾选「完成」。
Future<void> runTasksAuto({
  required List<String> taskIds,
  bool markDoneWhenFinished = true,
});

/// 取消后续任务（不打断正在跑的这一轮）。
void cancelAutoRun();
```

`_run()` 内部仍是同一套不变式：`_running` 保证同会话串行；每轮开始前设
`_runningTaskId`，循环体 `await resend(taskId: ...)` 就自然等到这一轮流式结束。

### 3.2 每项的步骤

```
1. 取 task（不存在则跳过）；
2. seed：任务下还没有 user 消息时，插入一条 content = task.promptText 的
   user 消息（taskId 打标），并且内容为空 → 记为「跳过（无内容）」直接下一项；
   —— 这段逻辑从 session_chat_panel 的 _startTask 提进 controller，公开为
      Future<bool> seedTaskMessage(TaskItem task)，面板与自动执行共用一份；
3. await resend(taskId: task.id)（= 用整个会话历史跑一轮，方案 B 不变）；
4. controller.error != null → 记失败，按 D3 的策略停下/继续；
5. markDoneWhenFinished → task.done = true; await save()（写 XML，不调
   AppState.persistSession，避免整表刷新）；
6. 进入下一项。
```

`stop()`（输入栏的「停止」）在自动执行期间同时置 `_autoCancelled = true`，
所以「停止当前轮」= 也停掉整条链，不会偷偷继续跑下一项。

### 3.3 UI

`lib/ui/widgets/task_session_view.dart`

- **任务列表头**：新增「自动执行」按钮（`FilledButton.icon(play_arrow)`）；
  - 没有未完成任务 → 禁用；
  - 有任意轮次在跑（`running == true`）→ 禁用；
  - 自动执行中 → 变成「停止自动执行」（`stop` 图标）+ 文案
    `自动执行中 2/5`（数据来自 controller 的 `autoRunning/autoDoneCount/autoTotal`）。
- **点击后先弹一次确认框**（`showAutoRunDialog`）：
  - 范围：`仅未开始的任务`（默认） / `全部未完成的任务（含已有回复的，会再跑一轮）`；
  - 复选：`每项完成后自动勾选「完成」`（默认开）；
  - 显示将执行 N 项 + 前 3 项标题预览；N == 0 时按钮禁用。
- **行内进度**：当前项用 `runningTaskId`（已有）；轮次之间的空档用
  `autoCurrentTaskId` 高亮，避免「闪一下就没了」。
- **任务对话头部** `TaskChatHeader`：自动执行中在副标题位置显示
  `自动执行中 2/5 · 点此停止`（放一个 `TextButton`），不需要回到列表才能停。
- **进度与用量（按 D5：不跟随、不展示文本流）**：
  - 主区**停在任务列表**，头部副标题显示 `自动执行 2/5 · 本次已用 入 xx / 出 xx`
    （`autoUsage` = 会话累计用量 − 开跑时快照）；
  - 当前执行行：spinner + 「自动执行中…」（`autoCurrentTaskId` 覆盖轮次之间的空档）；
  - 结束后汇总 SnackBar：`自动执行完成：N 项` / `已停止：完成 N/M 项` /
    `第 k 项「…」失败：…`（并提示可重跑）。
  - `TaskListView` 自己监听 controller（AppState 只在「是否在跑」翻转时通知，
    进度/用量变化不会触发重建）。

### 3.4 边界

| 情况 | 行为 |
|---|---|
| 自动执行中切到别的会话 | 链条继续（controller 常驻），回到该会话仍在跑 |
| 自动执行中点「停止」/ 停止自动执行 | 当前轮中止 + 后续不再开始 |
| 某轮报错（网络、审批被拒、预算用尽后模型决定不继续） | 默认暂停整条链并 SnackBar 说明第几项失败 |
| 任务内容与标题都为空 | 跳过该任务，计一条 notice，不影响后续 |
| 用户手动改了某个已完成任务的勾选 | 下一次自动执行重新按「未完成」筛选，不缓存队列 |
| 只有一个会话一个引擎 | 期间用户自己再点发送 → 被 `_running` 挡下（与现在一致） |

---

## 4. 拍板结果（已确认，实现按此执行）

| 编号 | 问题 | 结论 |
|---|---|---|
| D1 | 自动执行范围 | ✅ 弹确认框，默认「仅未开始的任务」，可切「全部未完成」 |
| D2 | 每项跑完是否自动勾「完成」 | ✅ 默认勾选；用户可关掉（关掉=只跑不标记） |
| D3 | 某任务报错 | ✅ 暂停整条链并提示，且**重跑从报错的那一项开始**（controller 记 `autoResumeTaskId`，确认框默认「从上次中断的 X 开始」） |
| D4 | 已完成任务能否被自动执行 | ✅ 不能（需先取消勾选）—— 与需求二语义一致 |
| D5 | 自动执行时视图 | ✅ **停留在任务列表**：显示执行到哪一项 + 本次消耗 token，**不展示文本流** |
| D6 | 「自动执行」按钮位置 | ✅ 任务列表头（宽屏文字按钮，窄屏收成图标按钮 + tooltip） |
| D7 | 是否给「从这一项开始」入口 | ✅ 本轮不做（只有整队列 + 自动的断点续跑） |

---

## 5. 改动文件清单（拍板后执行）

- `lib/ui/pages/session_wizard_page.dart`：删最少任务校验 + 文案
- `lib/ui/widgets/task_session_view.dart`：列表头按钮/进度、确认框、空态按钮、
  对话头部自动执行提示、`_startTask` 改调 controller
- `lib/ui/widgets/input_area.dart`：`sendLocked` / `lockedHint`
- `lib/ui/pages/home_page.dart`：`taskDone` 传参、retry 隐藏、`_maybeStartTask` 早退、
  视图跟随（桌面 + 移动）
- `lib/session/session_controller.dart`：自动执行状态机 + `seedTaskMessage` +
  `cancelAutoRun` + `stop()` 联动
- `lib/models/task_item.dart`：`done` 注释（用户勾选 / 自动执行选项写入，agent 不写）
- 新增 `test/task_auto_run_test.dart`：队列筛选、seed、自动勾选完成、错误即停并记住断点、
  停止、跳过无内容项（用 `SessionController.debugTaskTurn` 顶替真联网的一轮）
- `FEATURES.md` §1.2/§7 相关行、`.memory/` 三件套

验证：`flutter analyze lib test` → `flutter test test/task_auto_run_test.dart` →
真机 `dist/build_apk.sh -p`。
