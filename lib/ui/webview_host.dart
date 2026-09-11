import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart' as iaw;
import 'package:flutter_inappwebview_platform_interface/flutter_inappwebview_platform_interface.dart'
    show WebUri;
import 'package:path/path.dart' as path;
import 'package:webview_flutter/webview_flutter.dart' as wf;

import '../bridge/bridge_api.dart';
import '../bridge/bridge_events.dart';
import 'local_web_server.dart';

/// 桌面端(exe / Linux 可执行文件)Flutter 资源根目录。
/// 移动 / macOS / Web 用不到,只在 Platform.isWindows || Platform.isLinux 时使用。
final String _flutterAssetsRoot = path.join(
  path.dirname(Platform.resolvedExecutable),
  'data',
  'flutter_assets',
);

/// 平台分流:
/// - Android / iOS / macOS  -> webview_flutter(WKWebView / Android System WebView)
/// - Windows / Linux / Web  -> flutter_inappwebview(WebView2 / WebKitGTK / 浏览器原生)
bool get _useInAppWebView =>
    kIsWeb || Platform.isWindows || Platform.isLinux;

class WebViewHost extends StatefulWidget {
  const WebViewHost({super.key});

  @override
  State<WebViewHost> createState() => _WebViewHostState();
}

class _WebViewHostState extends State<WebViewHost> {
  /// webview_flutter 路径(Android / iOS / macOS)
  wf.WebViewController? _wfCtrl;

  /// flutter_inappwebview 路径(Windows / Linux / Web),由 _IaWWebView 写回。
  iaw.InAppWebViewController? _iawCtrl;

  /// 初始化用到的回调:controller 创建时记录下来,后续通过它 evalJs / loadUrl。
  /// webview_flutter 路径不会用到。
  void _onIawController(iaw.InAppWebViewController c) {
    _iawCtrl = c;
  }

  @override
  void initState() {
    super.initState();
    if (!_useInAppWebView) {
      _wfCtrl = wf.WebViewController();
      _initWebViewFlutter();
    }
    _subscribeEvents();
  }

  /// webview_flutter 路径(Android / iOS / macOS)
  Future<void> _initWebViewFlutter() async {
    final c = _wfCtrl!;
    try {
      await c.setJavaScriptMode(wf.JavaScriptMode.unrestricted);
    } catch (e) {
      debugPrint('[XChat] setJavaScriptMode FAILED: $e');
    }
    try {
      await c.setOnConsoleMessage(
        (msg) => debugPrint('[WebView console][${msg.level.name}] ${msg.message}'),
      );
    } catch (e) {
      debugPrint('[XChat] setOnConsoleMessage FAILED: $e');
    }
    try {
      await c.setNavigationDelegate(wf.NavigationDelegate(
        onPageStarted: (u) => debugPrint('[XChat][nav] onPageStarted: $u'),
        onPageFinished: (u) => debugPrint('[XChat][nav] onPageFinished: $u'),
        onWebResourceError: (e) =>
            debugPrint('[XChat][nav] onWebResourceError: ${e.errorType} ${e.description} url=${e.url}'),
      ));
    } catch (e) {
      debugPrint('[XChat] setNavigationDelegate FAILED: $e');
    }
    try {
      await c.addJavaScriptChannel(
        'XchatNative',
        onMessageReceived: (msg) => _handleNativeMessage(msg.message, _evalJsWf),
      );
      debugPrint('[XChat] addJavaScriptChannel OK');
    } catch (e, st) {
      debugPrint('[XChat] addJavaScriptChannel FAILED: $e\n$st');
    }
    try {
      await c.loadFlutterAsset('assets/web/index.html');
      debugPrint('[XChat] loadFlutterAsset OK');
    } catch (e, st) {
      debugPrint('[XChat] loadFlutterAsset FAILED: $e\n$st');
    }
    unawaited(_probe(_evalJsWf, 't0'));
    await Future.delayed(const Duration(seconds: 2));
    unawaited(_probe(_evalJsWf, 't2'));
  }

  /// JS→Dart 通道收到消息后,统一处理。
  /// [evalJs] 由调用方注入(不同 WebView 实现有不同的 API),
  /// 保证下面的 setTimeout(...,0) 防 Windows 上 callback 漏发的修复两路都生效。
  Future<void> _handleNativeMessage(
    String raw,
    Future<void> Function(String js) evalJs,
  ) async {
    try {
      final req = jsonDecode(raw) as Map<String, dynamic>;
      final method = req['method'] as String;
      final args = (req['args'] as Map?)?.cast<String, dynamic>() ?? {};
      final cb = req['cb'] as String?;
      final res = await BridgeApi.handle(method, args);
      if (cb != null) {
        final js =
            'setTimeout(()=>{try{window["$cb"](${res['ok'] ? 'true' : 'false'}, ${jsonEncode(res['payload'])});}catch(e){console.error("[cb err]",e)}},0);';
        await evalJs(js);
      }
    } catch (e) {
      debugPrint('bridge handle error: $e');
    }
  }

  /// webview_flutter 的 evalJs 封装。
  Future<void> _evalJsWf(String js) async {
    try {
      await _wfCtrl?.runJavaScript(js);
    } catch (_) {
      // runJavaScript 在未就绪时可能抛,忽略即可
    }
  }

  /// 探针(只用于 debug,失败不阻塞)。
  Future<void> _probe(
    Future<void> Function(String js) evalJs,
    String tag,
  ) async {
    try {
      // 注:runJavaScriptReturningResult 在 inappwebview 上没有等效 API,
      // 这里只在 webview_flutter 路径打印;inappwebview 路径下 _probe 不执行。
      if (_wfCtrl == null) return;
      final res = await _wfCtrl!.runJavaScriptReturningResult(
        'JSON.stringify({'
          'tag: ${jsonEncode(tag)}, '
          'ready: document.readyState, '
          'appHTML: (document.getElementById("app") && document.getElementById("app").innerHTML || "").length, '
          'hasXchat: typeof window.xchat, '
          'hasRouter: typeof window.Router'
          '})',
      );
      debugPrint('[XChat][probe $tag] $res');
    } catch (e) {
      debugPrint('[XChat][probe $tag] FAILED: $e');
    }
  }

  void _subscribeEvents() {
    final events = [
      'chunk', 'tool_start', 'tool_done', 'round', 'usage',
      'session_continued', 'compressed', 'confirm_required',
      'blocked_layer_a', 'blocked_exception_yolo',
      'error', 'done', 'fx_refreshed', 'confirm_mode_changed',
      'theme_changed', 'file_changed', 'editor_opened',
      'assistant_done', 'user_appended',
    ];
    for (final ev in events) {
      BridgeEvents.on(ev).listen((payload) {
        final js =
            'window._xchat_dispatch && window._xchat_dispatch(${jsonEncode(ev)}, ${jsonEncode(payload)});';
        if (_wfCtrl != null) {
          // ignore: unawaited_futures
          _evalJsWf(js);
        } else if (_iawCtrl != null) {
          // ignore: unawaited_futures
          _iawCtrl!.evaluateJavascript(source: js);
        }
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: SafeArea(
        child: _useInAppWebView
            ? _IaWWebView(
                onController: _onIawController,
                onNativeMessage: _handleNativeMessage,
              )
            : wf.WebViewWidget(controller: _wfCtrl!),
      ),
    );
  }
}

/// flutter_inappwebview 路径的 widget 容器(Windows / Linux / Web)。
/// 事件监听(controller / loadStart / loadStop / loadError / consoleMessage)
/// 全部通过 InAppWebView widget 的回调注册,不在 controller 上调用 addOn*。
class _IaWWebView extends StatefulWidget {
  const _IaWWebView({
    required this.onController,
    required this.onNativeMessage,
  });
  final void Function(iaw.InAppWebViewController c) onController;
  final Future<void> Function(
    String raw,
    Future<void> Function(String js) evalJs,
  ) onNativeMessage;

  @override
  State<_IaWWebView> createState() => _IaWWebViewState();
}

class _IaWWebViewState extends State<_IaWWebView> {
  iaw.InAppWebViewController? _ctrl;

  @override
  void dispose() {
    super.dispose();
  }

  Future<void> _evalJs(String js) async {
    final c = _ctrl;
    if (c == null) return;
    try {
      await c.evaluateJavascript(source: js);
    } catch (_) {}
  }

  @override
  Widget build(BuildContext context) {
    // 桌面平台走本地 HTTP server(避开 WebKit file:// 子资源跨文件限制)
    // Web 平台用占位 URL(具体适配不在本次改动范围)
    Widget webview = iaw.InAppWebView(
      initialUrlRequest: iaw.URLRequest(url: WebUri('about:blank')),
      initialSettings: iaw.InAppWebViewSettings(
        javaScriptEnabled: true,
        transparentBackground: true,
        supportZoom: false,
        useShouldInterceptAjaxRequest: false,
        useShouldInterceptFetchRequest: false,
        mediaPlaybackRequiresUserGesture: false,
      ),
      onWebViewCreated: (c) {
        _ctrl = c;
        widget.onController(c);
      },
      onConsoleMessage: (c, msg) {
        // ConsoleMessageLevel 没有 name() / toValue(),只用 toString() 拿调试输出
        debugPrint('[WebView console][${msg.messageLevel}] ${msg.message}');
      },
      onLoadStart: (c, u) => debugPrint('[XChat][nav] onPageStarted: $u'),
      onLoadStop: (c, u) => debugPrint('[XChat][nav] onPageFinished: $u'),
      onReceivedError: (c, req, err) =>
          debugPrint('[XChat][nav] onReceivedError: ${err.description} url=${req.url}'),
      onReceivedHttpError: (c, req, resp) =>
          debugPrint('[XChat][nav] onHttpError: ${req.url}'),
    );

    // Windows / Linux:启动本地 HTTP server,加载入口 URL
    if (!kIsWeb && (Platform.isWindows || Platform.isLinux)) {
      webview = Builder(builder: (ctx) {
        Future.microtask(() async {
          try {
            final assetsWeb = path.join(_flutterAssetsRoot, 'assets', 'web');
            final server = await LocalWebServer.start(assetsWeb);
            debugPrint('[XChat] local web server at ${server.baseUrl} (root=$assetsWeb)');
            await _ctrl?.loadUrl(
              urlRequest: iaw.URLRequest(url: WebUri(server.baseUrl)),
            );
          } catch (e, st) {
            debugPrint('[XChat] iaw load FAILED: $e\n$st');
          }
        });
        return webview;
      });
    }

    // 注册 JS→Dart 桥接。JS 端用 window.flutter_inappwebview.callHandler('XchatNative', payload)
    // 通过 _ctrl.addJavaScriptHandler 注册(必须在 onWebViewCreated 之后执行)。
    // 用 PostFrameCallback 等 controller 落地。
    WidgetsBinding.instance.addPostFrameCallback((_) {
      final c = _ctrl;
      if (c == null) return;
      try {
        c.addJavaScriptHandler(
          handlerName: 'XchatNative',
          callback: (args) async {
            final raw = args.isNotEmpty ? args[0].toString() : '{}';
            await widget.onNativeMessage(raw, _evalJs);
            return null;
          },
        );
        debugPrint('[XChat] iaw addJavaScriptHandler OK');
      } catch (e, st) {
        debugPrint('[XChat] iaw addJavaScriptHandler FAILED: $e\n$st');
      }
    });

    return webview;
  }
}