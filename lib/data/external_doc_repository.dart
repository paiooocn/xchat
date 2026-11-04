import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import '../models/external_doc.dart';
import 'atomic_file.dart';

/// 单个外部文件的大小上限：超过就不读正文（界面提示用外部编辑器打开）。
const int kExternalDocMaxBytes = 4 * 1024 * 1024;

/// 目录扫描的默认上限。
const int kExternalScanMaxDepth = 3;
const int kExternalScanMaxFiles = 800;

/// 认作 Markdown 的扩展名（大小写不敏感）。
const Set<String> kExternalMdExtensions = <String>{'.md', '.markdown'};

/// [path] 是否是 Markdown 文件（按扩展名）。
bool isMarkdownPath(String path) =>
    kExternalMdExtensions.contains(p.extension(path).toLowerCase());

/// 系统选择器给出的「临时副本」路径判定（位于缓存目录内）。
///
/// Android / iOS 的 `file_picker` 常把选中的文件复制到应用缓存再给路径 ——
/// 往这种路径写回去不会影响用户的原始文件，所以要禁用编辑。
bool isTransientCopyPath(String path, String? cacheDir) {
  if (cacheDir == null || cacheDir.trim().isEmpty) return false;
  return p.isWithin(
    p.normalize(p.absolute(cacheDir)),
    p.normalize(p.absolute(path)),
  );
}

/// 读 / 写用户磁盘上的外部 Markdown 文件（**不写 front-matter**）。
///
/// 目录扫描只 `stat` 不读正文；打开时才读，正文换行统一成 `\n`（写回按原
/// 文件的行尾还原），BOM 原样保留。
class ExternalDocRepository {
  ExternalDocRepository({this.cacheDir});

  /// 缓存目录（判断「临时副本」用）；未给定时按需探测。
  String? cacheDir;

  /// 缓存目录（用于判断「临时副本」）；探测失败时为空串（视为可写）。
  Future<String?> cacheDirectory() async {
    final cached = cacheDir;
    if (cached != null) return cached;
    try {
      cacheDir = (await getTemporaryDirectory()).path;
    } catch (_) {
      // 插件不可用（单元测试）→ 不判定，按可写处理。
      cacheDir = '';
    }
    return cacheDir;
  }

  /// 扫描 [dir] 内的 Markdown 文件（递归，最多 [maxDepth] 层，最多 [maxFiles] 个）。
  ///
  /// 跳过：`.` 开头的隐藏文件/目录、符号链接目录、无读权限的目录。
  /// [notesDir] 给定时，位于其中的文件标记为「本机笔记」（点击走内部笔记视图）。
  Future<ExternalMdScan> scanDirectory(
    String dir, {
    int maxDepth = kExternalScanMaxDepth,
    int maxFiles = kExternalScanMaxFiles,
    String? notesDir,
  }) async {
    final root = p.normalize(p.absolute(dir));
    final directory = Directory(root);
    if (!await directory.exists()) {
      return ExternalMdScan(root: root, error: '目录不存在');
    }
    final notesRoot = (notesDir == null || notesDir.trim().isEmpty)
        ? null
        : p.normalize(p.absolute(notesDir));
    final files = <ExternalMdEntry>[];
    var truncated = false;

    Future<void> walk(Directory current, int depth) async {
      if (truncated) return;
      List<FileSystemEntity> children;
      try {
        children = await current.list(followLinks: false).toList();
      } on FileSystemException {
        return; // 无权限的目录跳过，而不让整次扫描失败。
      }
      final subdirs = <Directory>[];
      for (final child in children) {
        final name = p.basename(child.path);
        if (name.startsWith('.')) continue;
        if (child is Link) continue;
        if (child is Directory) {
          subdirs.add(child);
          continue;
        }
        if (child is! File || !isMarkdownPath(child.path)) continue;
        if (files.length >= maxFiles) {
          truncated = true;
          return;
        }
        DateTime? modifiedAt;
        var sizeBytes = 0;
        try {
          final stat = await child.stat();
          modifiedAt = stat.modified;
          sizeBytes = stat.size;
        } on FileSystemException {
          // 拿不到 stat 也要列出来（打开时会再报错）。
        }
        final relative = p.relative(current.path, from: root);
        files.add(
          ExternalMdEntry(
            path: p.normalize(child.path),
            name: name,
            relativeDir: relative == '.' ? '' : relative,
            modifiedAt: modifiedAt,
            sizeBytes: sizeBytes,
            isInternalNote:
                notesRoot != null && p.isWithin(notesRoot, child.path),
          ),
        );
      }
      if (depth >= maxDepth) return;
      subdirs.sort((a, b) => a.path.compareTo(b.path));
      for (final sub in subdirs) {
        await walk(sub, depth + 1);
      }
    }

    await walk(directory, 0);
    files.sort((a, b) {
      final byDir = a.relativeDir.compareTo(b.relativeDir);
      if (byDir != 0) return byDir;
      return a.name.toLowerCase().compareTo(b.name.toLowerCase());
    });
    return ExternalMdScan(root: root, files: files, truncated: truncated);
  }

  /// 读一个 md 文件（UTF-8 容错、去 BOM、记录行尾风格与 mtime）。
  Future<ExternalDoc> read(String rawPath) async {
    final path = p.normalize(p.absolute(rawPath));
    final name = p.basename(path);
    final file = File(path);
    try {
      if (!await file.exists()) {
        return ExternalDoc(path: path, name: name, loadError: '文件不存在');
      }
      final stat = await file.stat();
      final doc = ExternalDoc(
        path: path,
        name: name,
        loadedMtime: stat.modified,
        sizeBytes: stat.size,
        writable: !isTransientCopyPath(path, await cacheDirectory()),
      );
      if (stat.size > kExternalDocMaxBytes) {
        doc.loadError = '文件过大（${doc.sizeLabel}），请用外部编辑器打开';
        return doc;
      }
      final bytes = await file.readAsBytes();
      if (bytes.contains(0)) {
        doc.loadError = '看起来不是文本文件';
        doc.writable = false;
        return doc;
      }
      // UTF-8 解码器会把文件开头的 BOM 直接吃掉，所以 BOM 只能按字节判断。
      var data = bytes;
      if (data.length >= 3 &&
          data[0] == 0xEF &&
          data[1] == 0xBB &&
          data[2] == 0xBF) {
        doc.bom = true;
        data = data.sublist(3);
      }
      var text = utf8.decode(data, allowMalformed: true);
      if (text.contains('\r\n')) {
        doc.crlf = true;
        text = text.replaceAll('\r\n', '\n');
      }
      doc.body = text;
      return doc;
    } on FileSystemException catch (error) {
      return ExternalDoc(
        path: path,
        name: name,
        loadError: '读取失败：${error.message}',
      );
    }
  }

  /// 逐字写回（无 front-matter）：换行与 BOM 按原文件还原。
  ///
  /// 抛 [FileSystemException]（调用方据此提示「保存失败」）。
  Future<void> write(ExternalDoc doc, String body) async {
    final normalized = body.replaceAll('\r\n', '\n').replaceAll('\r', '\n');
    var text = doc.crlf ? normalized.replaceAll('\n', '\r\n') : normalized;
    if (doc.bom) text = '\uFEFF$text';
    await writeAtomic(doc.path, text);
    doc.body = body;
    final stat = await File(doc.path).stat();
    doc.loadedMtime = stat.modified;
    doc.sizeBytes = stat.size;
  }

  Future<DateTime?> modifiedAt(String path) async {
    final file = File(path);
    if (!await file.exists()) return null;
    return (await file.stat()).modified;
  }

  Future<bool> exists(String path) => File(path).exists();
}
