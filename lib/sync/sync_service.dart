import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:flutter/foundation.dart';

import '../core/json_utils.dart';
import '../data/sync_repository.dart';
import '../models/sync_item.dart';
import '../state/app_state.dart';

/// One paired device's coordinates, parsed from a scanned QR code.
class SyncPairTarget {
  const SyncPairTarget({
    required this.host,
    required this.port,
    required this.code,
  });

  final String host;
  final int port;
  final String code;

  /// QR payload format: `xchatsync://pair?h=<ip>&p=<port>&c=<6 位配对码>`.
  static String encode({required String host, required int port, required String code}) =>
      Uri(
        scheme: 'xchatsync',
        host: 'pair',
        queryParameters: <String, String>{
          'h': host,
          'p': '$port',
          'c': code,
        },
      ).toString();

  /// Parses a scanned code. Returns null when it is not a pairing QR.
  static SyncPairTarget? parse(String text) {
    final raw = text.trim();
    if (raw.isEmpty) return null;
    final uri = Uri.tryParse(raw);
    if (uri == null) return null;
    if (uri.scheme != 'xchatsync' && uri.scheme != 'xchat-sync') return null;
    final host = uri.queryParameters['h']?.trim() ?? '';
    final port = int.tryParse(uri.queryParameters['p']?.trim() ?? '') ?? 0;
    final code = uri.queryParameters['c']?.trim() ?? '';
    if (host.isEmpty || port <= 0 || port > 65535) return null;
    if (code.length != 6) return null;
    return SyncPairTarget(host: host, port: port, code: code);
  }
}

/// Raised when a peer call cannot be completed; the message is shown as is.
class SyncFailure implements Exception {
  const SyncFailure(this.message);
  final String message;
  @override
  String toString() => message;
}

/// Which end of the link this device is.
enum _Role {
  /// 未配对。
  none,

  /// 显示配对码的一端：监听端口，所有对外请求走「任务队列」交给对方执行。
  host,

  /// 扫码 / 输码的一端：主动连 host，负责轮询任务并在本地执行。
  guest,
}

/// LAN peer-to-peer sync between two devices on the same network.
///
/// **Why only one direction carries traffic.** The pairing handshake only proves
/// that *guest → host* is reachable (the guest dialled the host). The reverse
/// direction routinely fails in the field: Android/ROM firewalls refuse inbound
/// connections, the ephemeral listening port dies when the page is rebuilt, and
/// Wi-Fi client isolation blocks peer traffic in ways that are hard to detect.
///
/// So the link is deliberately asymmetric, like a NAT-friendly protocol:
/// * **host** (显示配对码的一端) listens and never dials out. Anything it needs
///   from the peer becomes a task in a queue.
/// * **guest** (扫码/输码的一端) dials the host, executes queued tasks locally
///   and posts the results back.
///
/// Both screens still show both lists and both can trigger a 同步 — the
/// direction of the data is independent from the direction of the connection.
///
/// 归档的会话/项目不出现在任何一侧的清单里（`SyncRepository.manifest`），
/// 工作目录不传输（`SyncRepository.importItems`）。
class SyncService extends ChangeNotifier {
  SyncService(this.state)
      : repository = SyncRepository(
          paths: state.paths,
          indexRepository: state.indexRepository,
          sessionRepository: state.sessionRepository,
          projectRepository: state.projectRepository,
        );

  final AppState state;
  final SyncRepository repository;

  static const _prefix = '/xchat-sync';
  static const _tokenHeader = 'x-sync-token';

  /// How long a host-side call waits for the guest to answer.
  static const _taskTimeout = Duration(seconds: 30);

  /// Guest polling interval while idle.
  static const _pollInterval = Duration(milliseconds: 700);

  HttpServer? _server;
  _Role _role = _Role.none;
  String? _code;
  String? _token;
  String? _peerHost;
  int? _peerPort;
  int _pollGeneration = 0;
  int _taskSeq = 0;

  final List<Map<String, Object?>> _tasks = <Map<String, Object?>>[];
  final Map<String, Completer<Map<String, Object?>>> _pending =
      <String, Completer<Map<String, Object?>>>{};

  /// Human readable label of the paired device (its hostname).
  String peerDevice = '';

  /// This device's LAN address (shown under the pairing code, goes in the QR).
  String? localAddress;

  List<SyncItemSummary> localItems = <SyncItemSummary>[];
  List<SyncItemSummary> peerItems = <SyncItemSummary>[];

  String? status;
  String? error;
  bool busy = false;

  bool get listening => _server != null;
  bool get paired => _token != null && _role != _Role.none;
  bool get isHost => _role == _Role.host;
  int get port => _server?.port ?? 0;

  /// The 6-digit code this device currently offers (null = 未生成/已配对).
  String? get code => _code;

  /// 对端地址（host 只知道发来请求的 IP，端口对它无意义，只显示 IP）。
  String get peerAddress {
    if (!paired) return '';
    final port = _peerPort ?? 0;
    if (port <= 0) return '$_peerHost';
    return isHost ? '$_peerHost' : '$_peerHost:$port';
  }

  String get qrPayload {
    final address = localAddress ?? '';
    return SyncPairTarget.encode(host: address, port: port, code: _code ?? '');
  }

  /// Whether a camera based scan is available on this platform.
  static bool get canScan =>
      !kIsWeb && (Platform.isAndroid || Platform.isIOS || Platform.isMacOS);

  // ------------------------------------------------------------- pairing

  /// Starts listening and shows a fresh pairing code for the other device.
  Future<void> startPairing() async {
    if (paired) return;
    try {
      await _ensureServer();
      _code = _newCode();
      localAddress ??= await _detectLocalAddress();
      error = null;
      status = '配对码已生成：让对方扫码或输入配对码';
      await refreshLocal();
    } catch (e) {
      error = '无法监听局域网端口：$e';
    }
    notifyListeners();
  }

  /// Joins the device that is showing a pairing code (scan or manual entry).
  ///
  /// Only the guest needs the host's coordinates; the host learns everything
  /// from this request (its token, this device's label).
  Future<bool> pair({
    required String host,
    required int port,
    required String code,
  }) async {
    if (paired) return true;
    final target = host.trim();
    final trimmedCode = code.trim();
    if (target.isEmpty || port <= 0) {
      error = '请填写对方的地址与端口';
      notifyListeners();
      return false;
    }
    if (trimmedCode.length != 6) {
      error = '配对码必须是 6 位数字';
      notifyListeners();
      return false;
    }
    busy = true;
    error = null;
    notifyListeners();
    try {
      final token = _newToken();
      final response = await _send(
        'POST',
        '/pair',
        host: target,
        port: port,
        token: null,
        body: <String, Object?>{
          'code': trimmedCode,
          'device': _deviceLabel(),
          'token': token,
        },
      );
      if (response.error != null) {
        error = response.error;
        return false;
      }
      _token = token;
      _role = _Role.guest;
      _peerHost = target;
      _peerPort = port;
      peerDevice = asString(response.body['device']) ?? '';
      _code = null;
      status = '已连接：$peerDevice';
      await _reload();
      _startPolling();
      return true;
    } catch (e) {
      error = '连接失败：$e';
      return false;
    } finally {
      busy = false;
      notifyListeners();
    }
  }

  /// Drops the pairing and stops listening / polling.
  Future<void> unpair() async {
    final server = _server;
    _server = null;
    _pollGeneration++;
    _role = _Role.none;
    _token = null;
    _peerHost = null;
    _peerPort = null;
    _code = null;
    peerDevice = '';
    peerItems = <SyncItemSummary>[];
    localItems = <SyncItemSummary>[];
    status = null;
    error = null;
    busy = false;
    _failPending('已断开配对');
    notifyListeners();
    try {
      await server?.close(force: true);
    } catch (_) {
      // Already gone.
    }
  }

  @override
  void dispose() {
    final server = _server;
    _server = null;
    _pollGeneration++;
    _role = _Role.none;
    _failPending('同步页面已关闭');
    // Closing in the background: dispose() cannot await.
    unawaited(server?.close(force: true) ?? Future<void>.value());
    super.dispose();
  }

  // ---------------------------------------------------------------- lists

  Future<void> refreshLocal() async {
    localItems = await repository.manifest();
    notifyListeners();
  }

  Future<void> refreshPeer() async {
    if (!paired) {
      peerItems = <SyncItemSummary>[];
      notifyListeners();
      return;
    }
    try {
      final result = await _call('manifest', const <String, Object?>{});
      peerItems = _parseItems(result);
      error = null;
    } on SyncFailure catch (failure) {
      error = failure.message;
      peerItems = <SyncItemSummary>[];
    } catch (e) {
      error = '$e';
      peerItems = <SyncItemSummary>[];
    }
    notifyListeners();
  }

  Future<void> refresh() async {
    busy = true;
    error = null;
    notifyListeners();
    try {
      await refreshLocal();
      await refreshPeer();
    } catch (e) {
      error = '刷新失败：$e';
    } finally {
      busy = false;
      notifyListeners();
    }
  }

  Future<void> _reload() async {
    await refreshLocal();
    await refreshPeer();
  }

  /// Runs one 同步 for the ticked keys.
  ///
  /// Ticked keys present on the peer are pulled first, then the ticked keys
  /// present locally are pushed. A key existing on both sides is transferred in
  /// both directions — the newer `updated_at` wins, so the run converges.
  Future<SyncReport> runSync(Set<String> ticked) async {
    if (!paired) return SyncReport(notes: <String>['尚未配对']);
    if (ticked.isEmpty) return SyncReport(notes: <String>['请先勾选要同步的项']);
    // 勾选项目 = 连同它名下的会话一起同步（两侧的清单都参与展开：对端可能有
    // 本机还没有的会话）。
    final keys = Set<String>.of(ticked);
    for (final item in <SyncItemSummary>[...localItems, ...peerItems]) {
      if (item.projectId.isEmpty) continue;
      if (keys.contains('${SyncItemKind.project.name}:${item.projectId}')) {
        keys.add(item.key);
      }
    }
    busy = true;
    error = null;
    notifyListeners();
    final notes = <String>[];
    var pulled = 0;
    var pushed = 0;
    try {
      await refreshPeer();
      final running = state.runningSessionIds;
      bool blocked(SyncItemSummary item) =>
          item.kind == SyncItemKind.session && running.contains(item.id);

      final pullKeys = <String>[];
      for (final item in peerItems) {
        if (!keys.contains(item.key)) continue;
        if (blocked(item)) {
          notes.add('${item.title}：正在生成回答，本次跳过');
          continue;
        }
        pullKeys.add(item.key);
      }
      if (pullKeys.isNotEmpty) {
        final result = await _call('export', <String, Object?>{'keys': pullKeys});
        final payloads = <SyncItemPayload>[
          for (final item in asList(result['items'])) SyncItemPayload.fromJson(item),
        ];
        final outcome = await _importLocal(payloads);
        pulled = outcome.imported;
        notes.addAll(outcome.skipped);
      }

      final pushKeys = <String>[
        for (final item in localItems)
          if (keys.contains(item.key) && !blocked(item)) item.key,
      ];
      if (pushKeys.isNotEmpty) {
        final payloads = await repository.exportItems(pushKeys);
        if (payloads.isNotEmpty) {
          final result = await _call('import', <String, Object?>{
            'items': <Object?>[for (final p in payloads) p.toJson()],
          });
          pushed = asInt(result['imported']) ?? 0;
          for (final item in asList(result['skipped'])) {
            final text = asString(item);
            if (text != null) notes.add('对端：$text');
          }
        }
      }
      await _reload();
      status = '同步完成';
    } on SyncFailure catch (failure) {
      notes.add('同步失败：${failure.message}');
      error = failure.message;
    } catch (e) {
      notes.add('同步失败：$e');
      error = '$e';
    } finally {
      busy = false;
      notifyListeners();
    }
    return SyncReport(pulled: pulled, pushed: pushed, notes: notes);
  }

  List<SyncItemSummary> _parseItems(Map<String, Object?> result) => <SyncItemSummary>[
        for (final item in asList(result['items'])) SyncItemSummary.fromJson(item),
      ];

  /// Writes incoming items, then refreshes the local catalogs.
  Future<SyncImportOutcome> _importLocal(List<SyncItemPayload> payloads) async {
    final outcome = await repository.importItems(payloads);
    if (outcome.imported > 0) {
      await state.refreshAfterSync(outcome.touchedSessionIds);
      localItems = await repository.manifest();
      notifyListeners();
    }
    return outcome;
  }

  // -------------------------------------------------- 统一的动作（两侧共用）

  /// Executes one protocol action against the **local** catalogs.
  Future<Map<String, Object?>> _execute(
    String action,
    Map<String, Object?> args,
  ) async {
    switch (action) {
      case 'manifest':
        final items = await repository.manifest();
        return <String, Object?>{
          'items': <Object?>[for (final item in items) item.toJson()],
        };
      case 'export':
        final keys = <String>[
          for (final key in asList(args['keys'])) asString(key) ?? '',
        ].where((key) => key.isNotEmpty);
        final payloads = await repository.exportItems(keys);
        return <String, Object?>{
          'items': <Object?>[for (final p in payloads) p.toJson()],
        };
      case 'import':
        final payloads = <SyncItemPayload>[
          for (final item in asList(args['items'])) SyncItemPayload.fromJson(item),
        ];
        final outcome = await _importLocal(payloads);
        return <String, Object?>{
          'imported': outcome.imported,
          'skipped': outcome.skipped,
        };
      default:
        throw SyncFailure('未知操作：$action');
    }
  }

  /// Asks the peer to run [action]. Transparently uses the task queue when this
  /// side is the host (the host cannot dial out).
  Future<Map<String, Object?>> _call(
    String action,
    Map<String, Object?> args,
  ) async {
    if (!paired) throw const SyncFailure('尚未配对');
    if (_role == _Role.guest) {
      final response =
          await _send('POST', '/rpc', body: <String, Object?>{'action': action, 'args': args});
      if (response.error != null) throw SyncFailure(response.error!);
      return asMap(response.body['result']);
    }
    return _enqueue(action, args);
  }

  // ------------------------------------------------------------ 任务队列

  /// Queues [action] for the guest and waits for its answer.
  Future<Map<String, Object?>> _enqueue(
    String action,
    Map<String, Object?> args,
  ) async {
    final id = '${++_taskSeq}';
    final completer = Completer<Map<String, Object?>>();
    _pending[id] = completer;
    _tasks.add(<String, Object?>{'id': id, 'action': action, 'args': args});
    try {
      return await completer.future.timeout(_taskTimeout);
    } on TimeoutException {
      throw const SyncFailure('对端没有响应（它可能已离开同步页）');
    } finally {
      _pending.remove(id);
    }
  }

  void _failPending(String message) {
    _tasks.clear();
    for (final completer in _pending.values) {
      if (!completer.isCompleted) completer.completeError(SyncFailure(message));
    }
    _pending.clear();
  }

  /// Guest side: keeps asking the host for queued tasks and runs them locally.
  void _startPolling() {
    final generation = ++_pollGeneration;
    unawaited(_pollLoop(generation));
  }

  Future<void> _pollLoop(int generation) async {
    var failures = 0;
    while (paired && _role == _Role.guest && generation == _pollGeneration) {
      List<Object?> tasks;
      try {
        final response = await _send('POST', '/poll', body: const <String, Object?>{});
        if (response.error != null) throw SyncFailure(response.error!);
        tasks = asList(response.body['tasks']);
        failures = 0;
      } catch (e) {
        failures++;
        error = '与对端断开：${_describe(e)}（重试中…）';
        notifyListeners();
        await Future<void>.delayed(Duration(seconds: failures.clamp(1, 5)));
        continue;
      }
      if (tasks.isEmpty) {
        await Future<void>.delayed(_pollInterval);
        continue;
      }
      for (final raw in tasks) {
        await _runTask(asMap(raw));
      }
    }
  }

  Future<void> _runTask(Map<String, Object?> task) async {
    final id = asString(task['id']) ?? '';
    final action = asString(task['action']) ?? '';
    final args = asMap(task['args']);
    Map<String, Object?>? result;
    String? failure;
    try {
      result = await _execute(action, args);
    } catch (e) {
      failure = _describe(e);
    }
    try {
      await _send('POST', '/result', body: <String, Object?>{
        'id': id,
        'ok': failure == null,
        'result': result,
        'error': failure,
      });
    } catch (_) {
      // The host went away; the loop will notice on the next poll.
    }
  }

  // --------------------------------------------------------------- server

  Future<void> _ensureServer() async {
    if (_server != null) return;
    final server = await HttpServer.bind(InternetAddress.anyIPv4, 0);
    server.listen(_handle, onError: (Object _) {});
    _server = server;
    localAddress ??= await _detectLocalAddress();
  }

  Future<void> _handle(HttpRequest request) async {
    final segments = request.uri.pathSegments;
    final action = segments.isEmpty ? '' : segments.last;
    try {
      if (action == 'ping') {
        _writeJson(request.response, <String, Object?>{
          'app': 'xchat',
          'device': _deviceLabel(),
          'paired': paired,
        });
        return;
      }
      if (action == 'pair') {
        await _onPairRequest(request, await _readJson(request));
        return;
      }
      final token = request.headers.value(_tokenHeader);
      if (_token == null || token != _token) {
        _writeJson(request.response, <String, Object?>{'error': '未配对'},
            statusCode: 401);
        return;
      }
      final body = await _readJson(request);
      switch (action) {
        case 'rpc':
          _writeJson(request.response, await _runRpc(body));
          break;
        case 'poll':
          final tasks = List<Map<String, Object?>>.of(_tasks);
          _tasks.clear();
          _writeJson(request.response, <String, Object?>{'tasks': tasks});
          break;
        case 'result':
          final id = asString(body['id']) ?? '';
          final completer = _pending.remove(id);
          if (completer != null && !completer.isCompleted) {
            if (asBool(body['ok'], fallback: false)) {
              completer.complete(asMap(body['result']));
            } else {
              completer.completeError(
                  SyncFailure(asString(body['error']) ?? '对端处理失败'));
            }
          }
          _writeJson(request.response, <String, Object?>{'ok': true});
          break;
        default:
          _writeJson(request.response, <String, Object?>{'error': '未知接口'},
              statusCode: 404);
      }
    } catch (e) {
      try {
        _writeJson(request.response, <String, Object?>{'error': _describe(e)},
            statusCode: 500);
      } catch (_) {
        // The client already went away.
      }
    }
  }

  /// Runs one action for the caller (guest → host direction).
  Future<Map<String, Object?>> _runRpc(Map<String, Object?> body) async {
    final action = asString(body['action']) ?? '';
    final args = asMap(body['args']);
    try {
      final result = await _execute(action, args);
      return <String, Object?>{'ok': true, 'result': result};
    } on SyncFailure catch (failure) {
      return <String, Object?>{'ok': false, 'error': failure.message};
    } catch (e) {
      return <String, Object?>{'ok': false, 'error': _describe(e)};
    }
  }

  Future<void> _onPairRequest(
    HttpRequest request,
    Map<String, Object?> body,
  ) async {
    final offered = _code;
    if (offered == null) {
      _writeJson(request.response, <String, Object?>{'error': '本机还没有生成配对码'},
          statusCode: 409);
      return;
    }
    final code = asString(body['code'])?.trim() ?? '';
    if (code != offered) {
      _writeJson(request.response, <String, Object?>{'error': '配对码不正确'},
          statusCode: 403);
      return;
    }
    final token = asString(body['token'])?.trim() ?? '';
    final remote = request.connectionInfo?.remoteAddress.address ?? '';
    if (token.isEmpty || remote.isEmpty) {
      _writeJson(request.response, <String, Object?>{'error': '配对信息不完整'},
          statusCode: 400);
      return;
    }
    _token = token;
    _role = _Role.host;
    _peerHost = remote;
    // host 从不主动建连，所以不记录端口（对端是客户端，没有可连的监听口）。
    _peerPort = 0;
    peerDevice = asString(body['device']) ?? '';
    _code = null;
    error = null;
    status = '已连接：$peerDevice';
    _writeJson(request.response, <String, Object?>{
      'ok': true,
      'device': _deviceLabel(),
    });
    unawaited(_afterPaired());
  }

  Future<void> _afterPaired() async {
    try {
      await _reload();
    } catch (e) {
      error = '读取对端清单失败：${_describe(e)}';
      notifyListeners();
    }
  }

  Future<Map<String, Object?>> _readJson(HttpRequest request) async {
    final text = await utf8.decoder.bind(request).join();
    if (text.trim().isEmpty) return <String, Object?>{};
    try {
      return asMap(jsonDecode(text));
    } catch (_) {
      return <String, Object?>{};
    }
  }

  void _writeJson(
    HttpResponse response,
    Map<String, Object?> body, {
    int statusCode = 200,
  }) {
    response.statusCode = statusCode;
    response.headers.contentType =
        ContentType('application', 'json', charset: 'utf-8');
    final bytes = utf8.encode(jsonEncode(body));
    response.headers.contentLength = bytes.length;
    response.add(bytes);
    unawaited(response.close());
  }

  // --------------------------------------------------------------- client

  Future<_SyncResponse> _send(
    String method,
    String path, {
    String? host,
    int? port,
    String? token,
    Object? body,
  }) async {
    final target = host ?? _peerHost;
    final targetPort = port ?? _peerPort;
    if (target == null || targetPort == null || targetPort <= 0) {
      throw const SyncFailure('尚未配对');
    }
    final client = HttpClient()..connectionTimeout = const Duration(seconds: 6);
    try {
      final request = await client
          .openUrl(method, Uri.parse('http://$target:$targetPort$_prefix$path'))
          .timeout(const Duration(seconds: 10));
      final header = token ?? _token;
      if (header != null) request.headers.set(_tokenHeader, header);
      if (body != null) {
        final bytes = utf8.encode(jsonEncode(body));
        request.headers.contentType = ContentType.json;
        request.headers.contentLength = bytes.length;
        request.add(bytes);
      }
      final response = await request.close().timeout(const Duration(seconds: 40));
      final text = await response.transform(utf8.decoder).join();
      var json = <String, Object?>{};
      if (text.trim().isNotEmpty) {
        try {
          json = asMap(jsonDecode(text));
        } catch (_) {
          // Non-JSON body: the status code still tells us what happened.
        }
      }
      final error = response.statusCode == 200
          ? null
          : (asString(json['error']) ?? 'HTTP ${response.statusCode}');
      return _SyncResponse(json, error);
    } finally {
      client.close(force: true);
    }
  }

  // ---------------------------------------------------------------- utils

  static String _newCode() {
    final random = Random.secure();
    return (100000 + random.nextInt(900000)).toString();
  }

  static String _newToken() {
    final random = Random.secure();
    return base64Url.encode(<int>[for (var i = 0; i < 24; i++) random.nextInt(256)]);
  }

  static String _describe(Object error) {
    if (error is SyncFailure) return error.message;
    if (error is SocketException) {
      return '连不上对端（${error.osError?.message ?? error.message}）';
    }
    if (error is TimeoutException) return '对端超时';
    return '$error';
  }

  static String _deviceLabel() {
    String? name;
    try {
      name = Platform.localHostname.trim();
    } catch (_) {
      // Some platforms refuse to report a hostname.
    }
    // Android 的 localHostname 恒为 "localhost"，那不是一个能区分设备的标签。
    if (name != null && name.isNotEmpty && name != 'localhost') return name;
    if (Platform.isAndroid) return 'Android 设备';
    if (Platform.isIOS) return 'iOS 设备';
    if (Platform.isMacOS) return 'Mac';
    if (Platform.isWindows) return 'Windows 设备';
    return 'Linux 设备';
  }

  /// Best-effort LAN address of this device (private ranges first).
  Future<String?> _detectLocalAddress() async {
    try {
      final interfaces = await NetworkInterface.list(
        type: InternetAddressType.IPv4,
        includeLoopback: false,
      );
      String? candidate;
      for (final interface in interfaces) {
        for (final address in interface.addresses) {
          final ip = address.address;
          if (address.isLoopback || address.isLinkLocal) continue;
          if (_isPrivate(ip)) return ip;
          candidate ??= ip;
        }
      }
      return candidate;
    } catch (_) {
      return null;
    }
  }

  static bool _isPrivate(String ip) =>
      ip.startsWith('192.168.') || ip.startsWith('10.') || _is172Private(ip);

  static bool _is172Private(String ip) {
    if (!ip.startsWith('172.')) return false;
    final parts = ip.split('.');
    if (parts.length < 2) return false;
    final second = int.tryParse(parts[1]) ?? 0;
    return second >= 16 && second <= 31;
  }
}

class _SyncResponse {
  _SyncResponse(this.body, this.error);

  final Map<String, Object?> body;
  final String? error;
}
