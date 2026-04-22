import 'dart:ui';

import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:macos_window_utils/macos_window_utils.dart';

import 'app.dart';
import 'providers/service_providers.dart';

Future<void> _configureMacosWindow() async {
  await WindowManipulator.initialize(enableWindowDelegate: true);
  await WindowManipulator.makeTitlebarTransparent();
  await WindowManipulator.enableFullSizeContentView();
  await WindowManipulator.hideTitle();
}

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await _configureMacosWindow();

  final container = ProviderContainer();

  AppLifecycleListener(
    onExitRequested: () async {
      final controller = container.read(servicesControllerProvider.notifier);
      await controller.stopAll();
      return AppExitResponse.exit;
    },
  );

  runApp(UncontrolledProviderScope(
    container: container,
    child: const ViamProvisionerApp(),
  ));
}
