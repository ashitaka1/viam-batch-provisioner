import 'package:flutter/cupertino.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'features/shell/app_shell.dart';
import 'providers/preferences_providers.dart';
import 'theme/theme.dart';

class ViamProvisionerApp extends ConsumerWidget {
  const ViamProvisionerApp({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final platformBrightness = MediaQuery.platformBrightnessOf(context);
    final mode = ref.watch(themeModeProvider);
    final brightness = resolveBrightness(mode, platformBrightness);
    return CupertinoApp(
      title: 'Viam Provisioner',
      theme: cupertinoTheme(brightness),
      home: const AppShell(),
      debugShowCheckedModeBanner: false,
    );
  }
}
