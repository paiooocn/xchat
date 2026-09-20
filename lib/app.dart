import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import 'state/app_state.dart';
import 'ui/pages/home_page.dart';

class XChatApp extends StatelessWidget {
  const XChatApp({super.key});

  @override
  Widget build(BuildContext context) {
    final state = context.watch<AppState>();
    final themeMode = switch (state.config.themeMode) {
      'light' => ThemeMode.light,
      'dark' => ThemeMode.dark,
      _ => ThemeMode.system,
    };
    const seed = Color(0xFF3D5AFE);
    return MaterialApp(
      title: 'XChat',
      debugShowCheckedModeBanner: false,
      themeMode: themeMode,
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(seedColor: seed),
        useMaterial3: true,
      ),
      darkTheme: ThemeData(
        colorScheme: ColorScheme.fromSeed(
          seedColor: seed,
          brightness: Brightness.dark,
        ),
        useMaterial3: true,
      ),
      // Android 15+ draws the app edge-to-edge, so the bottom system inset
      // (virtual navigation buttons or the gesture bar) would otherwise cover
      // the app's bottom UI — most visibly the chat input bar. Reserve that
      // inset for the whole app, painting the strip with the scaffold color.
      // `padding.bottom` is used instead of `viewPadding.bottom` so it collapses
      // to zero while the soft keyboard is up (the Scaffold already resizes for
      // the keyboard), avoiding a gap above it.
      builder: (context, child) {
        if (child == null) return const SizedBox.shrink();
        final bottom = MediaQuery.paddingOf(context).bottom;
        if (bottom == 0) return child;
        return ColoredBox(
          color: Theme.of(context).scaffoldBackgroundColor,
          child: Padding(
            padding: EdgeInsets.only(bottom: bottom),
            child: MediaQuery.removePadding(
              context: context,
              removeBottom: true,
              child: child,
            ),
          ),
        );
      },
      home: const HomePage(),
    );
  }
}
