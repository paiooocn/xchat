/// A `sessions/*.xml` / `projects/*.xml` file that the catalog index does not
/// know about ("删漏" file).
///
/// Such files are invisible in the session list **and** in the LAN sync list;
/// the only place they show up is 「未索引文件管理」, which can either restore
/// them into the index or delete them for good.
class OrphanFile {
  OrphanFile({
    required this.kind,
    required this.id,
    required this.path,
    required this.title,
    required this.updatedAt,
    this.parsed = false,
    this.owner = '',
    this.error = '',
  });

  /// `session` / `project` (mirrors the orphan's kind in the sidebar icons).
  final String kind;
  final String id;

  /// Absolute path of the file on disk.
  final String path;
  final String title;
  final DateTime updatedAt;

  /// Whether the XML could be decoded. A file that fails to decode can only be
  /// deleted — restoring it would put garbage into the catalog.
  final bool parsed;

  /// Owner project id (sessions only; empty when standalone).
  final String owner;

  /// Why the file could not be decoded (empty when [parsed]).
  final String error;

  bool get isProject => kind == 'project';

  String get fileName => path.split('/').last;
}
