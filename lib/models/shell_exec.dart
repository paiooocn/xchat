/// Configurable shell launcher for the agent's `shell` tool.
///
/// Every command is executed by spawning one child process: [ShellExecConfig]
/// stores the user setting (`可执行文件` + `参数模板`), and
/// [ResolvedShellExec.argumentsFor] turns the raw command string into the
/// argument vector of that process.
///
/// Design notes:
/// * The `{command}` placeholder in the args template is replaced with the
///   whole command string as **one** argument (no extra quoting needed —
///   `Process.start` takes an args list, not a command line).
/// * A template without `{command}` appends the command as the last argument.
/// * Empty settings fall back to the historical defaults: `cmd /c {command}`
///   on Windows, `/bin/bash -lc {command}` elsewhere. An empty args template
///   with a non-empty executable is derived from the executable's basename, so
///   `powershell` gets `-Command …` and `bash` gets `-lc …` automatically.
/// * Settings UI candidates are platform-specific: `/bin/bash` on Linux/macOS,
///   `cmd.exe` / Windows PowerShell 5 / PowerShell 7 (full paths) on Windows.
/// * [commandSyntaxNotes] documents the quoting/escaping quirks that differ
///   from typing at a traditional console — verified by probes against
///   `cmd`, `powershell` and bash (see the notes for the exact findings).
library;

import 'dart:convert';
import 'dart:io';

/// Placeholder replaced with the full command string.
const String kShellCommandPlaceholder = '{command}';

/// Which syntax/escaping rules a shell follows.
enum ShellFamily {
  /// `cmd.exe`: `%VAR%`, `^` as the escape character, no usable `"`.
  cmd,

  /// `powershell.exe` / `pwsh.exe`: backtick escapes, `$` variables.
  powershell,

  /// bash/zsh/sh/fish (and `wsl` forwarding to one): backslash escapes.
  posix,

  /// Anything else: generic advice only.
  unknown,
}

/// Classifies [executable] by its basename (case-insensitive, `.exe` optional).
ShellFamily shellFamilyFor(String executable) {
  final lower = _basename(executable).toLowerCase();
  final stem = lower.endsWith('.exe') ? lower.substring(0, lower.length - 4) : lower;
  return switch (stem) {
    'cmd' => ShellFamily.cmd,
    'powershell' || 'pwsh' => ShellFamily.powershell,
    'bash' || 'zsh' || 'sh' || 'fish' || 'ksh' || 'wsl' => ShellFamily.posix,
    _ => ShellFamily.unknown,
  };
}

String _basename(String path) {
  final index = path.lastIndexOf(RegExp(r'[/\\]'));
  return index < 0 ? path : path.substring(index + 1);
}

/// Command-writing rules for the LLM, per [family]. Includes the universal
/// non-interactive caveat plus the quoting/escaping differences measured
/// under `Process.start` (e.g. `cmd` mangles `"` into `\"`, PowerShell uses
/// backtick — not backslash — as its escape character).
String commandSyntaxNotes(ShellFamily family) {
  const common = '【通用】命令以非交互方式执行（stdin 非终端）：禁止需要人工输入、确认或分页的命令'
      '（如 pause、set /p、read、sudo 密码提示、git 凭据弹窗、less），否则会挂起直至超时。'
      'stdout/stderr 全量返回，优先按 UTF-8 解码，失败时回退系统编码。';
  return switch (family) {
    ShellFamily.cmd => '$common\n'
        '【cmd.exe】严禁在命令中使用双引号 "：实测经进程参数传递后会被破坏为反斜杠加引号'
        '（echo "ab" 实际输出 \\"ab\\"）。含空格的路径请改用 PowerShell/bash 执行，'
        '或使用 8.3 短路径（如 C:\\Progra~1）、先 cd /d 到目录再用相对路径。'
        '反斜杠 \\ 是路径分隔符、不是转义符；元字符 & | < > ^ 需转义时用 ^；'
        '变量用 %VAR%（截取 %VAR:~0,5%、替换 %VAR:a=b%），多条命令用 & / && / || 连接。',
    ShellFamily.powershell => '$common\n'
        '【PowerShell】转义符是反引号 `：`n 表示换行、`" 表示双引号、`` 表示反引号本身；'
        '反斜杠 \\ 是普通字符，路径 C:\\dir 与 C:/dir 均可直接写。'
        '单引号内全字面量、双引号内可展开 \$变量；环境变量用 \$env:NAME；'
        '命令间用 ; 连接（&& 与 || 仅 PowerShell 7 支持）；'
        '传给外部程序的参数含空格时照常加引号。',
    ShellFamily.posix => '$common\n'
        '【POSIX shell（bash/zsh/sh）】转义符是反斜杠 \\；单引号内全字面量，'
        '双引号内可展开 \$变量、\\ 仍可转义；反斜杠转义序列（\\n 等）的解释依赖具体命令'
        '（echo 不一定生效，格式化输出统一用 printf）。'
        '变量 \$VAR、命令替换 \$(...)、管道 |、&& || 、; 均与控制台一致；'
        '非交互模式下别名不生效，请写完整命令名。',
    ShellFamily.unknown => '$common\n'
        '【自定义 shell】按该 shell 自身的语法书写；注意命令文本中的双引号与反斜杠转义'
        '在经进程参数传递后可能与控制台直输不同，尽量避免二者混用。',
  };
}

/// Decodes captured child output: strict UTF-8 first, falling back to the
/// system encoding (GBK on a Chinese Windows) so non-UTF-8 output degrades to
/// readable text instead of throwing [FormatException].
String decodeShellOutput(List<int> bytes) {
  if (bytes.isEmpty) return '';
  try {
    return utf8.decode(bytes);
  } on FormatException {
    // Not UTF-8: fall back to the system encoding (GBK on a Chinese Windows).
  }
  try {
    return systemEncoding.decode(bytes);
  } on FormatException {
    // Last resort: never throw on captured output, show replacement chars.
    return const Utf8Decoder(allowMalformed: true).convert(bytes);
  }
}

/// A one-tap fill-in offered by the settings UI.
class ShellExecPreset {
  const ShellExecPreset({
    required this.id,
    required this.label,
    required this.executable,
    required this.argsTemplate,
  });

  final String id;
  final String label;
  final String executable;
  final String argsTemplate;
}

/// Preset that resets both fields to the platform defaults.
const ShellExecPreset kShellExecPresetDefault = ShellExecPreset(
  id: 'default',
  label: '跟随系统默认',
  executable: '',
  argsTemplate: '',
);

/// Windows candidates (full paths): cmd / Windows PowerShell 5 / PowerShell 7.
const List<ShellExecPreset> kShellExecPresetsWindows = <ShellExecPreset>[
  kShellExecPresetDefault,
  ShellExecPreset(
    id: 'cmd',
    label: '命令提示符（cmd.exe）',
    executable: r'C:\Windows\System32\cmd.exe',
    argsTemplate: '/c $kShellCommandPlaceholder',
  ),
  ShellExecPreset(
    id: 'powershell',
    label: 'Windows PowerShell 5',
    executable: r'C:\Windows\System32\WindowsPowerShell\v1.0\powershell.exe',
    argsTemplate: '-NoProfile -NonInteractive -Command $kShellCommandPlaceholder',
  ),
  ShellExecPreset(
    id: 'pwsh',
    label: 'PowerShell 7（pwsh.exe）',
    executable: r'C:\Program Files\PowerShell\7\pwsh.exe',
    argsTemplate: '-NoProfile -NonInteractive -Command $kShellCommandPlaceholder',
  ),
];

/// Linux/macOS candidates: bash.
const List<ShellExecPreset> kShellExecPresetsPosix = <ShellExecPreset>[
  kShellExecPresetDefault,
  ShellExecPreset(
    id: 'bash',
    label: 'bash',
    executable: '/bin/bash',
    argsTemplate: '-lc $kShellCommandPlaceholder',
  ),
];

/// Candidates offered by the settings UI for the current platform.
List<ShellExecPreset> shellExecPresets({required bool isWindows}) =>
    isWindows ? kShellExecPresetsWindows : kShellExecPresetsPosix;

/// Raw user setting: either field may be empty (see the library docs).
class ShellExecConfig {
  const ShellExecConfig({this.executable = '', this.argsTemplate = ''});

  /// Shell executable, e.g. `cmd`, `powershell`, `/bin/bash`, or a full path.
  final String executable;

  /// Argument template; `{command}` marks where the command string goes.
  final String argsTemplate;

  /// True when both fields are blank, i.e. the platform default applies.
  bool get isDefault => executable.trim().isEmpty && argsTemplate.trim().isEmpty;

  /// Fills in the platform/exe defaults and returns the spawn parameters.
  ResolvedShellExec resolve({required bool isWindows}) {
    final exe = executable.trim();
    final resolvedExe = exe.isEmpty ? (isWindows ? 'cmd' : '/bin/bash') : exe;
    final template = argsTemplate.trim();
    return ResolvedShellExec(
      executable: resolvedExe,
      argsTemplate: template.isEmpty ? defaultArgsTemplateFor(resolvedExe, isWindows: isWindows) : template,
    );
  }

  /// Derives an args template from [executable]'s basename (lower-cased, without
  /// an `.exe` suffix); unknown shells get `-lc {command}`.
  static String defaultArgsTemplateFor(String executable, {required bool isWindows}) {
    final name = _basename(executable).toLowerCase();
    final stem = name.endsWith('.exe') ? name.substring(0, name.length - 4) : name;
    return switch (stem) {
      'cmd' => '/c $kShellCommandPlaceholder',
      'powershell' || 'pwsh' => '-NoProfile -NonInteractive -Command $kShellCommandPlaceholder',
      'wsl' => '-e bash -lc $kShellCommandPlaceholder',
      'sh' => '-c $kShellCommandPlaceholder',
      _ => isWindows ? '/c $kShellCommandPlaceholder' : '-lc $kShellCommandPlaceholder',
    };
  }
}

/// Spawn parameters with all defaults resolved.
class ResolvedShellExec {
  const ResolvedShellExec({required this.executable, required this.argsTemplate});

  final String executable;
  final String argsTemplate;

  /// Builds the argument vector for [command].
  List<String> argumentsFor(String command) {
    final template = argsTemplate.trim();
    final tokens = template.isEmpty
        ? const <String>[]
        : template.split(RegExp(r'\s+')).where((t) => t.isNotEmpty).toList(growable: false);
    final args = <String>[];
    var injected = false;
    for (final token in tokens) {
      if (token.contains(kShellCommandPlaceholder)) {
        args.add(token.replaceAll(kShellCommandPlaceholder, command));
        injected = true;
      } else {
        args.add(token);
      }
    }
    if (!injected) args.add(command);
    return args;
  }
}
