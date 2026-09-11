import 'dart:io';

import 'package:path/path.dart' as p;

class PathEscapeError implements Exception {
  final String sandbox;
  final String attempted;
  PathEscapeError(this.sandbox, this.attempted);
  @override
  String toString() => 'PathEscapeError: $attempted escapes sandbox $sandbox';
}

class PathGuard {
  /// 解析并校验：返回 canonical 绝对路径；越界抛 PathEscapeError
  static String resolve(String sandbox, String userPath) {
    final sb = p.canonicalize(p.absolute(sandbox));
    var abs = p.absolute(p.join(sb, userPath));
    // 不解析 symlink（默认），避免绕过边界
    abs = p.canonicalize(abs);

    final cmp = Platform.isWindows ? abs.toLowerCase() : abs;
    final sbCmp = Platform.isWindows ? sb.toLowerCase() : sb;
    if (cmp != sbCmp && !cmp.startsWith(sbCmp + p.separator)) {
      throw PathEscapeError(sb, abs);
    }
    return abs;
  }
}
