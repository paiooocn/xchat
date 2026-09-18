import 'dart:io';

import 'package:path/path.dart' as p;

/// Result of trying to open a file in an external editor.
class EditorLaunchResult {
  const EditorLaunchResult(this.ok, this.message);

  final bool ok;
  final String message;
}

/// Opens [filePath] using the configured [command] template or the system
/// default handler. `{file}` in [command] is replaced with the path.
Future<EditorLaunchResult> openInEditor(String filePath, String command) async {
  if (!(Platform.isLinux || Platform.isMacOS || Platform.isWindows)) {
    return const EditorLaunchResult(false, '当前平台不支持外部编辑器，请使用内置编辑器');
  }
  try {
    if (command.trim().isNotEmpty) {
      final parts = _split(command.replaceAll('{file}', filePath));
      if (parts.isEmpty) {
        return const EditorLaunchResult(false, '编辑器命令为空');
      }
      await Process.start(parts.first, parts.sublist(1), mode: ProcessStartMode.detached);
      return EditorLaunchResult(true, '已用 ${parts.first} 打开');
    }
    // Fall back to the OS default handler.
    if (Platform.isMacOS) {
      await Process.start('open', [filePath], mode: ProcessStartMode.detached);
    } else if (Platform.isWindows) {
      await Process.start('cmd', ['/c', 'start', '', filePath], mode: ProcessStartMode.detached);
    } else {
      await Process.start('xdg-open', [filePath], mode: ProcessStartMode.detached);
    }
    return EditorLaunchResult(true, '已用系统默认程序打开 ${p.basename(filePath)}');
  } catch (error) {
    return EditorLaunchResult(false, '打开失败：$error');
  }
}

List<String> _split(String input) {
  final result = <String>[];
  final buffer = StringBuffer();
  var quote = '';
  for (var i = 0; i < input.length; i++) {
    final char = input[i];
    if (quote.isNotEmpty) {
      if (char == quote) {
        quote = '';
      } else {
        buffer.write(char);
      }
    } else if (char == '"' || char == "'") {
      quote = char;
    } else if (char == ' ') {
      if (buffer.isNotEmpty) {
        result.add(buffer.toString());
        buffer.clear();
      }
    } else {
      buffer.write(char);
    }
  }
  if (buffer.isNotEmpty) result.add(buffer.toString());
  return result;
}
