import 'dart:async';

import 'package:flutter/material.dart';

import 'config/blocklist_loader.dart';
import 'config/config_manager.dart';
import 'config/fx_rates.dart';
import 'ui/webview_host.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await ConfigManager.instance.init();
  await BlocklistLoader.instance.load();
  // 不阻塞启动;真 unawaited 来自 dart:async(空实现会让 Future 永远不执行)。
  unawaited(FxRates.refresh(silent: true));
  runApp(const XChatApp());
}

class XChatApp extends StatelessWidget {
  const XChatApp({super.key});
  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'XChat',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(useMaterial3: true, brightness: Brightness.light),
      darkTheme: ThemeData(useMaterial3: true, brightness: Brightness.dark),
      home: const WebViewHost(),
    );
  }
}