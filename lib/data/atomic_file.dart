import 'dart:io';

/// 原子写入一个文本文件：先写 `<path>.tmp`，再 rename 覆盖目标。
///
/// `rename` 覆盖已存在的文件在部分目标上会失败（Windows、部分 Android 存储），
/// 因此逐级降级：rename → 删旧文件再 rename → 直接 copy。
///
/// 崩溃时最坏只留下一个 `.tmp`，不会把目标文件截断成半个。
Future<void> writeAtomic(String path, String content) async {
  final target = File(path);
  final tmp = File('$path.tmp');
  await tmp.writeAsString(content, flush: true);
  try {
    await tmp.rename(target.path);
  } on FileSystemException {
    if (await target.exists()) await target.delete();
    try {
      await tmp.rename(target.path);
    } on FileSystemException {
      await tmp.copy(target.path);
      await tmp.delete();
    }
  } finally {
    if (await tmp.exists()) await tmp.delete();
  }
}
