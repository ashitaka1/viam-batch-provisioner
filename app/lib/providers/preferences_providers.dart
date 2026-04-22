import 'package:flutter/cupertino.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/platform_utils.dart';

enum AppThemeMode { system, light, dark }

/// User-selected theme. Persisted only in-memory for the session; the
/// system default is used on a fresh app launch.
final themeModeProvider =
    StateProvider<AppThemeMode>((ref) => AppThemeMode.system);

/// Resolves [AppThemeMode] against the current platform brightness.
Brightness resolveBrightness(
  AppThemeMode mode,
  Brightness platformBrightness,
) {
  return switch (mode) {
    AppThemeMode.light => Brightness.light,
    AppThemeMode.dark => Brightness.dark,
    AppThemeMode.system => platformBrightness,
  };
}

/// Lists all network interfaces on the host (macOS `networksetup`).
final networkInterfacesProvider = FutureProvider<List<String>>((ref) async {
  return listNetworkInterfaces();
});

/// Auto-detected default ethernet/thunderbolt interface.
final defaultNetworkInterfaceProvider = FutureProvider<String?>((ref) async {
  return defaultEthernetInterface();
});

/// User-selected interface for the PXE watcher. `null` means auto-detect.
final selectedNetworkInterfaceProvider = StateProvider<String?>((ref) => null);
