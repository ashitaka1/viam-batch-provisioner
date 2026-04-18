import 'dart:ui';

import 'package:flutter/cupertino.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'app.dart';
import 'providers/service_providers.dart';

void main() {
  final container = ProviderContainer();

  // Stop any running child processes (dnsmasq, pxe-watcher, embedded HTTP)
  // before the app terminates.
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
