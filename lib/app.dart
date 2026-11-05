import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import 'core/app_brand.dart';
import 'state/app_state.dart';
import 'ui/pages/home_page.dart';
import 'ui/theme/app_theme.dart';

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
    return MaterialApp(
      title: kAppBrandName,
      debugShowCheckedModeBanner: false,
      themeMode: themeMode,
      theme: AppTheme.light(),
      darkTheme: AppTheme.dark(),
      // Android 15+ draws the app edge-to-edge, so the system insets (status
      // bar on top, virtual navigation buttons / gesture bar at the bottom)
      // would otherwise cover the app's own UI — most visibly the sidebar's
      // brand row and the chat input bar. Reserve both insets for the whole
      // app, painting the strips with the scaffold color.
      // `padding` is used instead of `viewPadding` so the bottom collapses to
      // zero while the soft keyboard is up (the Scaffold already resizes for
      // the keyboard), avoiding a gap above it.
      builder: (context, child) {
        if (child == null) return const SizedBox.shrink();
        final media = MediaQuery.of(context);
        final top = media.padding.top;
        final bottom = media.padding.bottom;
        if (top == 0 && bottom == 0) return child;
        return ColoredBox(
          color: Theme.of(context).scaffoldBackgroundColor,
          child: Padding(
            padding: EdgeInsets.only(top: top, bottom: bottom),
            child: MediaQuery.removePadding(
              context: context,
              removeTop: top > 0,
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
