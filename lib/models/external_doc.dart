/// 外部 Markdown 文件（笔记目录之外、用户磁盘上的 `.md`）。
///
/// 与内部笔记（[Note]）**刻意分开**：外部文件不写 front-matter、不进
/// `index.json`，正文逐字读写（BOM / CRLF 原样还原）。
library;

/// 侧栏里的一个候选 md 文件。
///
/// 只来自目录扫描 / 单文件打开，**不读正文**（标题用文件名，扫描只 `stat`）。
class ExternalMdEntry {
  ExternalMdEntry({
    required this.path,
    required this.name,
    this.relativeDir = '',
    this.modifiedAt,
    this.sizeBytes = 0,
    this.isInternalNote = false,
  });

  /// 绝对路径（唯一键）。
  final String path;

  /// 文件名（含扩展名）。
  final String name;

  /// 相对扫描根目录的目录部分（`''` = 根层）。
  final String relativeDir;

  final DateTime? modifiedAt;
  final int sizeBytes;

  /// 该文件其实是一篇本机内部笔记（位于 `<root>/notes/`）——侧栏换图标，
  /// 点击仍走内部笔记视图，避免同一文件有两个真相。
  final bool isInternalNote;
}

/// 一次目录扫描的结果。
class ExternalMdScan {
  ExternalMdScan({
    required this.root,
    List<ExternalMdEntry>? files,
    this.truncated = false,
    this.error,
  }) : files = files ?? <ExternalMdEntry>[];

  /// 归一化后的根目录绝对路径。
  final String root;
  final List<ExternalMdEntry> files;

  /// 命中文件数 / 深度上限（界面据此提示「还有更多未显示」）。
  final bool truncated;

  /// 目录不存在 / 无权限等错误文案。
  final String? error;
}

/// 已经打开的那个外部文件（正文已读入）。
class ExternalDoc {
  ExternalDoc({
    required this.path,
    required this.name,
    this.body = '',
    this.readOnly = true,
    this.loadedMtime,
    this.crlf = false,
    this.bom = false,
    this.sizeBytes = 0,
    this.writable = true,
    this.loadError,
  });

  final String path;
  final String name;

  /// 已规范化的正文（换行统一成 `\n`，BOM 已剥离）。
  String body;

  /// 只读态（默认 true；需用户显式「开启编辑」才为 false）。
  bool readOnly;

  /// 打开时的 mtime，用于检测「打开之后被别的程序改过」。
  DateTime? loadedMtime;

  /// 原文件是 CRLF 行尾（写回时还原）。
  bool crlf;

  /// 原文件带 UTF-8 BOM（写回时还原）。
  bool bom;

  int sizeBytes;

  /// 是否可以写回（来自系统选择器的临时副本、非文本、过大时为 false）。
  bool writable;

  /// 读失败原因（不存在 / 权限 / 过大 / 非文本）；非空时 [body] 无意义。
  String? loadError;

  bool get ok => loadError == null;

  /// 大小的人类可读文案。
  String get sizeLabel {
    if (sizeBytes < 1024) return '$sizeBytes B';
    if (sizeBytes < 1024 * 1024) {
      return '${(sizeBytes / 1024).toStringAsFixed(1)} KB';
    }
    return '${(sizeBytes / (1024 * 1024)).toStringAsFixed(1)} MB';
  }
}
