# 计划：API Key 输入框对齐 novelwriter（恢复安卓系统粘贴）

状态：**仅规划，未改代码。** 目标文件：`lib/ui/pages/providers_page.dart`（`_ProviderEditorPage`）。

## 1. 背景与依据

- 现象：xchat 安卓版「模型服务 → 编辑 → API Key」无法复制/粘贴；已加的
  「从剪贴板粘贴」按钮 + 「显示密码」切换**均无效**。
- 对照：`novelwriter`（同一份 `/home/yimo/.toolchain/flutter` = Flutter 3.47.7、
  同样 `windowSoftInputMode="adjustResize"`、同样 Android 目标）的 API Key 框
  **长按系统粘贴即可用**，且它**没有**任何粘贴/可见性补丁：

  ```dart
  // novelwriter lib/ui/pages/settings_page.dart `_edit()`
  TextField(controller: apiKey,
            decoration: const InputDecoration(labelText: 'API Key(本地服务可留空)'),
            obscureText: true)
  ```

- 结论（上一轮已论证）：不是 SDK 版本问题；「密码框禁用复制/剪切」是框架既有设计
  （`EditableTextState.copyEnabled/cutEnabled` 恒含 `!obscureText`），两边一致。
  xchat 与之相比**多出来的参数才有嫌疑**，其中 `autocorrect: false` 最可疑
  （关闭自动更正后部分 IME 连建议条/剪贴板条都不显示，且不受「显示密码」影响）。

## 2. 对齐基准（验收形态）

xchat 的 API Key 字段最终只剩三要素：**controller + labelText + `obscureText: true`**，
不再有 `autocorrect` / `enableSuggestions` / `keyboardType` / `suffixIcon` 覆盖。

## 3. 差异与处置

| 差异项 | xchat 现状 | 处置 | 理由 |
| --- | --- | --- | --- |
| 遮挡切换 `_obscureApiKey` | 有（眼睛按钮） | **删** | novelwriter 恒遮挡；就地切 `obscureText` 在 `EditableText.didUpdateWidget` 里只 `updateConfig()`（且仅当已有输入连接），Android IME 不重新 attach 就不刷新 → 用户看到「按了没反应」 |
| `suffixIcon`（粘贴 + 眼睛，两个 `IconButton`） | 有 | **删** | 默认 48×48 ×2 ≈ 96px 挤压输入区与长按命中区，长按落到图标上不出菜单 |
| `_pasteApiKey()` | 有 | **删** | 自造通道；`Clipboard.getData` 在 Android 10+ 需窗口焦点、部分 ROM 直接返回 null，代码把 null 一律报「剪贴板为空」，误导排查 |
| `import 'package:flutter/services.dart'` | 有 | **删** | 该文件里只有 `Clipboard` 用到（`grep` 仅 2 处命中），删方法后成 unused_import |
| `autocorrect: false` | 有 | **删（回默认 true）** | 头号嫌疑：它改变输入类型标志，IME 判定「无更正/无建议」时通常连剪贴板条一起隐藏 |
| `enableSuggestions: true` | 显式 | **删（默认即 true）** | 无行为变化，减少噪音 |
| `keyboardType: TextInputType.text` | 显式 | **删（默认等价）** | `maxLines == 1` 默认就是 text；且绝不能改成 `visiblePassword`（仍是密码语义） |
| 容器（整页 `Scaffold + ListView`，API Key 是第 4 个字段） | — | **暂不动**（P1 观察项） | 与 novelwriter 的 `AlertDialog` 不同；`adjustResize` 下该行可能被键盘挤出可见区，先做 P0 验证再判断是否需要额外滚动/`ensureVisible` |
| labelText 文案 | `API Key` | 保持 `API Key`（不强求对齐 novelwriter 的「本地服务可留空」） | 文案与粘贴无关；如需一致性可另议 |

## 4. 精确改动清单（P0，单文件）

`lib/ui/pages/providers_page.dart`：

1. 删 `import 'package:flutter/services.dart';`。
2. `_ProviderEditorPageState`：删字段 `bool _obscureApiKey = true;` 及其文档注释。
3. 删方法 `_pasteApiKey()`（整段，含「剪贴板为空」提示）。
4. `build` 中 API Key 的 `TextField` 收缩为：

   ```dart
   TextField(
     controller: _apiKey,
     obscureText: true,
     decoration: const InputDecoration(labelText: 'API Key'),
   ),
   ```

   （`initState` 的 `_apiKey.text = provider.apiKey` 保留；`_applyTo` 的
   `apiKey = _apiKey.text.trim()` 不动。）

**不动**：`ProviderConfig.apiKey`、`lib/llm/llm_factory.dart`、
`packages/llm_api`、存储/导入导出格式、models.dev 向导页。

## 5. 分阶段与回滚

- **P0（一次到位）**：按 §4 严格对齐，出一个 APK 真机验证。改动小、单 commit，
  `git revert` 即可完整回滚。
- **P1（仅在 P0 仍不可粘贴时做）**：依次排查
  ①字段是否被键盘遮挡（是否需要在获得焦点时 `Scrollable.ensureVisible`）；
  ②换 IME（Gboard ↔ 讯飞）复现；③从「普通文本框（Base URL）」长按粘贴是否正常
  （以区分「密码语义」与「剪贴板/ROM 权限」）；④`obscureText` 改 false 裸测，
  确认是否残留密码语义影响。
- **P2（产品可选，非对齐必需）**：若确实需要「看明文核对 key」，加
  **B 方案**——眼睛按钮保留但切换时先 `FocusScope.of(context).unfocus()`、
  `await SchedulerBinding.instance.endOfFrame` 后 `requestFocus()`，强制 IME 重新
  attach（这是唯一能真正刷新输入类型的方式）；**不要**再用应用内 `Clipboard` 粘贴。

## 6. 验证

- 真机（Android，新装 APK）：模型服务 → 编辑 → 点进 API Key → 长按 →
  菜单出现「粘贴」→ 从其它 App 复制的 key 粘贴成功 → 保存 → 「测试连接」通过。
- 桌面（Linux/Windows）：`Ctrl+V` 仍可用，行为无回退。
- `flutter analyze lib`：无 `unused_import` / unused field 告警。
- `flutter test`：现有测试没有针对该字段的断言（`grep` 仅在 `test/note_ai_test.dart`
  提到 apiKey 的概念，不涉及该 UI），预期全绿。
- 若 P0 仍失败 → 记录 IME/ROM 型号后进 P1，不要回头加回 `Clipboard` 补丁。

## 7. 已拍板（用户，最终形态）

- **取消「眼睛」按钮**；**保留「粘贴」按钮**；其余**对齐 novelwriter** 的 API Key 输入框。
- 已按此实现（2026-11-05），实际代码见 `lib/ui/pages/providers_page.dart`
  `_ProviderEditorPageState`：`TextField(controller: _apiKey, focusNode: _apiKeyFocus,
  obscureText: true, decoration: InputDecoration(labelText: 'API Key', suffixIcon: 粘贴按钮))`。
- §4（删除式 P0）与 §8 原 P2-B（含眼睛按钮）**作废**，仅留档。

## 8. 实现要点（已落地）

1. 去掉 `_obscureApiKey`（不再需要状态），字段恒 `obscureText: true`。
2. 去掉 `autocorrect: false` / `enableSuggestions: true` / `keyboardType: TextInputType.text`
   三个覆盖，回到默认（与 novelwriter 一致；这三个正是 IME 判定「无建议 → 不显示剪贴板条」的嫌疑）。
3. 新增 `FocusNode _apiKeyFocus`（`dispose` 释放），挂 `focusNode: _apiKeyFocus`；
   `_pasteApiKey()` 读剪贴板前先 `requestFocus()`（Android 按**窗口焦点**判读取权限）。
4. `_pasteApiKey()` 三段判定，不再把一切失败都说成「剪贴板为空」：
   非 `resumed` → 「应用不在前台…」；`data == null` → 「无法读取剪贴板（系统或 ROM 限制），
   请长按输入框用系统粘贴」；`text` 空 → 「剪贴板为空」；成功 → **「已从剪贴板粘贴 N 个字符」**。
   读剪贴板包了 try/catch（平台通道异常也会报出来）。
5. `suffixIcon` 只剩一个粘贴按钮，且收紧为 `visualDensity: compact / padding: zero /
   40×40`，不再吃掉输入区与长按命中区。

## 9. 剪贴板能不能读到（结论与前提）

> **2026-11-05 真机更正**：上一版把「自造读取」和「系统粘贴」当成同一条通道，**这是错的**。
> 键盘上的「粘贴」由 IME 通过 **InputConnection.commitText** 直接把文本提交给 Flutter，
> **根本不调用 `Clipboard.getData`**；只有 Flutter 自己画的工具栏（`EditableTextState.pasteText`）
> 才用 `Clipboard.getData`。所以「系统能粘、应用读不到」是完全可能的组合——本机已实测：
> 点应用内按钮拿到的是 **非 null 的 `ClipboardData` 但 `text` 为空**（不是 null），
> 说明平台层把读取结果抹成了空串（无窗口焦点 / ROM 隐私策略 / 无读取权限），
> 而 `Clipboard.hasStrings` 之类的查询同样受限。
>
> 由此得到的现实结论：**在拒绝应用级剪贴板读取的设备上，自造粘贴按钮无法救活**，
> 唯一可靠通道是系统/键盘的「粘贴」（走 InputConnection，不经过这条限制）。
> 目前按钮已改为：读失败时明确提示「请长按输入框用键盘上的『粘贴』」。

**能，但和「系统长按粘贴」是同一条通道**，所以按钮并没有额外的读取能力：

- Dart 侧 `Clipboard.getData(kTextPlain)` → `SystemChannels.platform 'Clipboard.getData'` →
  Android `ClipboardManager.getPrimaryClip()?.getItemAt(0)?.coerceToText()`；框架自己的
  `EditableTextState.pasteText` 走的也是这一条。**两者要么都能读，要么都读不到。**
- 按钮唯一多出来的价值：**跳过 IME 是否展示那个"粘贴"菜单项**，以及跳过框架
  `_allowPaste` 要求"selection 有效"的限制（未聚焦过的字段 selection 为 -1，系统粘贴会静默无效）。
- 读不到的四种情形（都会返回 `null` 或空串）：
  1. 应用没有**窗口焦点**（弹着 Dialog / 通知抽屉 / 应用在后台）；
  2. 部分 ROM 的「后台读取剪贴板」隐私开关（MIUI / HarmonyOS / ColorOS）；
  3. 来源 App 把剪贴内容标记为 sensitive（密码管理器常见），个别 ROM 会直接给空白；
  4. 剪贴板里是图片/URI 而非纯文本（`kTextPlain` 拿不到）。
- **判定矩阵**（真机一分钟，不改代码）：先在 Base URL 这种普通框长按 → 若能看到"粘贴"且能贴，
  说明系统剪贴板正常；再点 API Key 的按钮，看提示是「剪贴板为空」还是「已粘贴 N 个字符」——
  前者＝读不到（焦点/ROM），后者但框里没变＝插入/重建问题。

## 10. 验收（本次实现）

- 真机：点「粘贴」→ 出现「已从剪贴板粘贴 N 个字符」且框内实质变化；长按输入框若系统菜单
  不给粘贴，则以此按钮为唯一通道（属预期，不再纠结 IME）。保存后「测试连接」通过。
- 真机（若按钮报「无法读取剪贴板」）：按 §9 判定矩阵排查焦点/ROM。
- 桌面：`Ctrl+V` 正常，粘贴按钮行为不变。
- `flutter analyze lib` 无 unused / deprecated 告警；`flutter test` 预期全绿。
