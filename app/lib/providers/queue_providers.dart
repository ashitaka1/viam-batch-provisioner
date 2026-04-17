import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/file_watcher.dart';
import '../core/repo_root.dart';
import '../data/queue_repository.dart';
import '../models/batch.dart';
import '../models/queue_entry.dart';
import 'environment_providers.dart';

final queueRepositoryProvider = Provider<QueueRepository>((ref) {
  return QueueRepository(ref.watch(repoRootProvider));
});

final queueEntriesProvider = StreamProvider<List<QueueEntry>>((ref) async* {
  final repo = ref.watch(queueRepositoryProvider);

  yield await repo.loadQueue();

  final dir = Directory(repo.machinesDir);
  await dir.create(recursive: true);
  final watcher = DebouncedFileWatcher(
    dir,
    duration: const Duration(milliseconds: 250),
  );
  ref.onDispose(watcher.dispose);

  await for (final _ in watcher.stream) {
    yield await repo.loadQueue();
  }
});

final batchTargetTypeProvider = StreamProvider<BatchTargetType?>((ref) async* {
  final repo = ref.watch(queueRepositoryProvider);

  Future<BatchTargetType?> read() async {
    final raw = await repo.loadTargetType();
    return switch (raw) {
      'pi' => BatchTargetType.pi,
      'x86' => BatchTargetType.x86,
      _ => null,
    };
  }

  yield await read();

  final dir = Directory(repo.machinesDir);
  await dir.create(recursive: true);
  final watcher = DebouncedFileWatcher(
    dir,
    duration: const Duration(milliseconds: 250),
  );
  ref.onDispose(watcher.dispose);

  await for (final _ in watcher.stream) {
    yield await read();
  }
});

final currentBatchProvider = Provider<Batch?>((ref) {
  final entries = ref.watch(queueEntriesProvider).valueOrNull;
  if (entries == null || entries.isEmpty) return null;

  final env = ref.watch(activeEnvironmentProvider).valueOrNull;
  final storedTarget = ref.watch(batchTargetTypeProvider).valueOrNull;
  return Batch(
    prefix: _derivePrefix(entries),
    entries: entries,
    targetType: storedTarget ?? BatchTargetType.pi,
    provisionMode: env?.provisionMode ?? 'os-only',
  );
});

String _derivePrefix(List<QueueEntry> entries) {
  final first = entries.first.name;
  final match = RegExp(r'^(.*?)-\d+$').firstMatch(first);
  return match?.group(1) ?? first;
}

final selectedStageIndexProvider = StateProvider<int>((ref) => 0);

/// Returns the currently selected stage, constrained to valid stages for the
/// active batch. When there's no batch, returns null.
final selectedStageProvider = Provider<BatchStage?>((ref) {
  final batch = ref.watch(currentBatchProvider);
  if (batch == null) return null;
  final idx = ref.watch(selectedStageIndexProvider);
  if (idx < 0 || idx >= batch.stages.length) return batch.stages.first;
  return batch.stages[idx];
});
