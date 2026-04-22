import 'package:flutter/material.dart' show ThemeMode;
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:macos_ui/macos_ui.dart';

import 'features/shell/app_shell.dart';
import 'providers/preferences_providers.dart';
import 'theme/theme.dart';

class ViamProvisionerApp extends ConsumerWidget {
  const ViamProvisionerApp({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final mode = ref.watch(themeModeProvider);
    final themeMode = switch (mode) {
      AppThemeMode.system => ThemeMode.system,
      AppThemeMode.light => ThemeMode.light,
      AppThemeMode.dark => ThemeMode.dark,
    };
    return MacosApp(
      title: 'Viam Provisioner',
      theme: macosLightTheme(),
      darkTheme: macosDarkTheme(),
      themeMode: themeMode,
      home: const AppShell(),
      debugShowCheckedModeBanner: false,
    );
  }
}
