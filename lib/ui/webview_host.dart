import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:path/path.dart' as path;
import 'package:webview_all/webview_all.dart';

import '../bridge/bridge_api.dart';
import '../bridge/bridge_events.dart';
import 'local_web_server.dart';

final String _flutterAssetsRoot = path.join(
  path.dirname(Platform.resolvedExecutable),
  'data',
  'flutter_assets',
);

class WebViewHost extends StatefulWidget {
  const WebViewHost({super.key});

  @override
  State<WebViewHost> createState() => _WebViewHostState();
}

class _WebViewHostState extends State<WebViewHost> {
  late final WebViewController _controller;

  @override
  void initState() {
    super.initState();
    _controller = WebViewController()
      ..setJavaScriptMode(JavaScriptMode.unrestricted)
      ..setNavigationDelegate(NavigationDelegate(
        onPageStarted: (url) => debugPrint('[XChat][nav] onPageStarted: $url'),
        onPageFinished: (url) => debugPrint('[XChat][nav] onPageFinished: $url'),
        onWebResourceError: (err) =>
            debugPrint('[XChat][nav] onWebResourceError: ${err.errorType} ${err.description} url=${err.url}'),
        onHttpError: (err) =>
            debugPrint('[XChat][nav] onHttpError: ${err.request?.uri}'),
        // onUrlChange 频繁(每次 hashchange / 资源请求都会触发),且打印的是 UrlChange 实例对象,
        // 噪音大于价值,这里不订阅。
      ))
      ..addJavaScriptChannel(
        'XchatNative',
        onMessageReceived: (msg) async {
          final raw = msg.message;
          try {
            final req = jsonDecode(raw) as Map<String, dynamic>;
            final method = req['method'] as String;
            final args = (req['args'] as Map?)?.cast<String, dynamic>() ?? {};
            final cb = req['cb'] as String?;
            final res = await BridgeApi.handle(method, args);
            if (cb != null) {
              final js =
                  'window["$cb"](${res['ok'] ? 'true' : 'false'}, ${jsonEncode(res['payload'])});';
              await _controller.runJavaScript(js);
            }
          } catch (e) {
            debugPrint('bridge handle error: $e');
          }
        },
      );

    // 起一个本地 HTTP server 把 assets/web 暴露成 http://127.0.0.1:port/
    // 这样 WebKit 才会把 <script src="js/*.js"> 当同源 http 请求执行。
    () async {
      debugPrint('[XChat] webview init');
      // console 监听提前到 loadRequest 之前,捕获首次 JS 错误
      try {
        await _controller.setOnConsoleMessage(
          (msg) =>
              debugPrint('[WebView console][${msg.level.name}] ${msg.message}'),
        );
        debugPrint('[XChat] setOnConsoleMessage OK');
      } catch (e, st) {
        debugPrint('[XChat] setOnConsoleMessage FAILED: $e\n$st');
      }
      try {
        final assetsWeb = path.join(_flutterAssetsRoot, 'assets', 'web');
        final server = await LocalWebServer.start(assetsWeb);
        debugPrint('[XChat] local web server at ${server.baseUrl} (root=$assetsWeb)');
        await _controller.loadRequest(Uri.parse(server.baseUrl));
        debugPrint('[XChat] loadRequest OK');
      } catch (e, st) {
        debugPrint('[XChat] local server / loadRequest FAILED: $e\n$st');
        try {
          await _controller.loadFlutterAsset('assets/web/index.html');
          debugPrint('[XChat] loadFlutterAsset fallback OK');
        } catch (e2, st2) {
          debugPrint('[XChat] loadFlutterAsset fallback FAILED: $e2\n$st2');
        }
      }
      // 注意: window.xchat 已由 assets/web/js/bridge.js 同步注入,
      // 这里不再额外 runJavaScript(BridgeApi.kXchatJs),避免重复定义
      // 且消除与 DOMContentLoaded 的竞争。
      // 探针
      Future<void> probe(String tag) async {
        try {
          final res = await _controller.runJavaScriptReturningResult(
            'JSON.stringify({'
              'tag: ${jsonEncode(tag)}, '
              'ready: document.readyState, '
              'bodyText: (document.body && document.body.innerText || "").length, '
              'appHTML: (document.getElementById("app") && document.getElementById("app").innerHTML || "").length, '
              'hasXchat: typeof window.xchat, '
              'hasDispatch: typeof window._xchat_dispatch, '
              'hasRouter: typeof window.Router, '
              'location: location.href'
            '})',
          );
          debugPrint('[XChat][probe $tag] $res');
        } catch (e, st) {
          debugPrint('[XChat][probe $tag] FAILED: $e\n$st');
        }
      }

      await probe('t0');
      await Future.delayed(const Duration(seconds: 2));
      await probe('t2');
    }();

    _subscribeEvents();
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
        _controller.runJavaScript(js);
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: SafeArea(child: WebViewWidget(controller: _controller)),
    );
  }
}
