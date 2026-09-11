import 'dart:async';
import 'dart:io';

import 'package:path/path.dart' as path;

/// 一个最小化的本地静态文件 HTTP 服务器,只为 WebView 提供 assets/web。
///
/// 绑 127.0.0.1,只接受 loopback 连接。目录外的请求一律 403。
/// 用途:WebKitGTK 在 file:// scheme 下默认禁止子资源跨文件加载,
/// 所有 <script src="js/*.js"> 会被静默拒掉(页面停在 readyState=loading,
/// 但不报错)。改成 http://127.0.0.1:port/ 后,子资源是同源 http 请求,
/// 能正常加载并执行。
class LocalWebServer {
  LocalWebServer._(this.port, this.root, this._server);

  final int port;
  final String root;
  final HttpServer _server;

  static const _mime = <String, String>{
    '.html': 'text/html; charset=utf-8',
    '.htm': 'text/html; charset=utf-8',
    '.js': 'application/javascript; charset=utf-8',
    '.mjs': 'application/javascript; charset=utf-8',
    '.css': 'text/css; charset=utf-8',
    '.json': 'application/json; charset=utf-8',
    '.svg': 'image/svg+xml',
    '.png': 'image/png',
    '.jpg': 'image/jpeg',
    '.jpeg': 'image/jpeg',
    '.gif': 'image/gif',
    '.ico': 'image/x-icon',
    '.woff': 'font/woff',
    '.woff2': 'font/woff2',
    '.ttf': 'font/ttf',
    '.map': 'application/json; charset=utf-8',
    '.txt': 'text/plain; charset=utf-8',
  };

  static LocalWebServer? _instance;
  static LocalWebServer get instance {
    final s = _instance;
    if (s == null) {
      throw StateError('LocalWebServer not started. Call LocalWebServer.start(root) first.');
    }
    return s;
  }

  static bool get isRunning => _instance != null;

  /// 启动一个本地静态服务器,服务 [root] 目录。
  /// [root] 通常是 `$bundle/data/flutter_assets/assets/web`。
  /// 返回绑定到的端口(0 表示让系统分配)。
  static Future<LocalWebServer> start(String root) async {
    if (_instance != null) return _instance!;
    final rootDir = Directory(root);
    if (!rootDir.existsSync()) {
      throw FileSystemException('assets root not found', root);
    }
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final local = LocalWebServer._(server.port, rootDir.resolveSymbolicLinksSync(), server);
    _instance = local;
    server.listen(local._handle, onError: (e, st) {
      // ignore: avoid_print
      print('[LocalWebServer] error: $e\n$st');
    });
    return local;
  }

  String get baseUrl => 'http://127.0.0.1:$port/';

  Future<void> stop() async {
    await _server.close(force: true);
    if (identical(_instance, this)) _instance = null;
  }

  Future<void> _handle(HttpRequest req) async {
    // 仅 GET/HEAD
    if (req.method != 'GET' && req.method != 'HEAD') {
      req.response.statusCode = HttpStatus.methodNotAllowed;
      await req.response.close();
      return;
    }

    // 把 URL 路径解码并清理,防 ../ 越权
    var rel = Uri.decodeComponent(req.uri.path);
    if (rel.startsWith('/')) rel = rel.substring(1);
    final normalized = path.normalize(rel);
    if (normalized.startsWith('..') || path.isAbsolute(normalized)) {
      req.response.statusCode = HttpStatus.forbidden;
      await req.response.close();
      return;
    }

    var file = File(path.join(root, normalized));
    if (!file.existsSync()) {
      // 目录请求:补 index.html
      final dir = Directory(path.join(root, normalized));
      if (dir.existsSync()) {
        file = File(path.join(dir.path, 'index.html'));
      }
    }
    if (!file.existsSync()) {
      req.response.statusCode = HttpStatus.notFound;
      req.response.headers.contentType = ContentType.text;
      req.response.write('not found: $normalized');
      await req.response.close();
      return;
    }

    final ext = path.extension(file.path).toLowerCase();
    final mime = _mime[ext] ?? 'application/octet-stream';
    req.response.headers.contentType = ContentType.parse(mime);
    req.response.headers.set('Cache-Control', 'no-store');

    if (req.method == 'HEAD') {
      final len = await file.length();
      req.response.headers.contentLength = len;
      await req.response.close();
      return;
    }

    await req.response.addStream(file.openRead());
    await req.response.close();
  }
}
