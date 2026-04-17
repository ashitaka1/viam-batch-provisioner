import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path/path.dart' as p;

import '../core/file_watcher.dart';
import '../core/repo_root.dart';
import '../data/environment_repository.dart';
import '../models/environment.dart';

final environmentRepositoryProvider = Provider<EnvironmentRepository>((ref) {
  return EnvironmentRepository(ref.watch(repoRootProvider));
});

final environmentListProvider =
    StreamProvider<List<String>>((ref) async* {
  final repo = ref.watch(environmentRepositoryProvider);
  final repoRoot = ref.watch(repoRootProvider);

  // Emit initial list
  yield await repo.listEnvironments();

  // Watch for changes
  final envDir = Directory(p.join(repoRoot, 'config', 'environments'));
  await envDir.create(recursive: true);
  final watcher = DebouncedFileWatcher(
    envDir,
    duration: const Duration(milliseconds: 500),
  );
  ref.onDispose(watcher.dispose);

  await for (final _ in watcher.stream) {
    yield await repo.listEnvironments();
  }
});

final activeEnvironmentNameProvider =
    StreamProvider<String?>((ref) async* {
  final repo = ref.watch(environmentRepositoryProvider);
  final repoRoot = ref.watch(repoRootProvider);

  yield await repo.getActiveEnvironment();

  final configDir = Directory(p.join(repoRoot, 'config'));
  final watcher = DebouncedFileWatcher(configDir);
  ref.onDispose(watcher.dispose);

  await for (final _ in watcher.stream) {
    yield await repo.getActiveEnvironment();
  }
});

final activeEnvironmentProvider =
    FutureProvider<Environment?>((ref) async {
  final name = ref.watch(activeEnvironmentNameProvider).valueOrNull;
  if (name == null) return null;
  final repo = ref.watch(environmentRepositoryProvider);
  return repo.loadEnvironment(name);
});
