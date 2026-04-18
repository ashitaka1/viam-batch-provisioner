import 'dart:async';
import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path/path.dart' as p;

import '../core/process_runner.dart';
import '../core/repo_root.dart';
import 'service_providers.dart';

enum PrepTask { setupPxe, buildConfig }

extension PrepTaskLabel on PrepTask {
  String get logTag => switch (this) {
        PrepTask.setupPxe => 'setup',
        PrepTask.buildConfig => 'build-config',
      };

  String scriptPath(String repoRoot) => switch (this) {
        PrepTask.setupPxe =>
          p.join(repoRoot, 'cli', 'setup-pxe-server.sh'),
        PrepTask.buildConfig =>
          p.join(repoRoot, 'cli', 'build-config.sh'),
      };

  /// Files this task is responsible for creating. If all exist, the task
  /// is considered "already done" and the operator can skip it.
  List<String> outputs(String repoRoot) => switch (this) {
        PrepTask.setupPxe => [
            p.join(repoRoot, 'netboot', 'grubx64.efi'),
            p.join(repoRoot, 'netboot', 'vmlinuz'),
            p.join(repoRoot, 'netboot', 'initrd'),
          ],
        PrepTask.buildConfig => [
            p.join(repoRoot, 'http-server', 'autoinstall', 'user-data'),
          ],
      };
}

/// Returns whether [task]'s output files all exist on disk.
final prepDoneProvider =
    FutureProvider.family<bool, PrepTask>((ref, task) async {
  final repoRoot = ref.watch(repoRootProvider);
  for (final path in task.outputs(repoRoot)) {
    if (!await File(path).exists()) return false;
  }
  return true;
});

class PrepStatus {
  const PrepStatus({this.running, this.lastError});
  final PrepTask? running;
  final String? lastError;

  bool get isBusy => running != null;
  bool isRunning(PrepTask t) => running == t;
}

class PrepController extends StateNotifier<PrepStatus> {
  PrepController(this._repoRoot, this._ref) : super(const PrepStatus());

  final String _repoRoot;
  final Ref _ref;
  StreamSubscription<ProcessEvent>? _sub;

  Future<void> run(PrepTask task) async {
    if (state.isBusy) return;
    await _sub?.cancel();

    final controller = _ref.read(servicesControllerProvider.notifier);
    final tag = task.logTag;
    controller.emitLog(tag, 'Running ${p.basename(task.scriptPath(_repoRoot))}…');

    state = PrepStatus(running: task);
    _sub = runProcess(
      executable: task.scriptPath(_repoRoot),
      arguments: const [],
      workingDirectory: _repoRoot,
    ).listen((event) {
      if (event is ProcessLine) {
        controller.emitLog(tag, event.line, isError: event.isError);
      } else if (event is ProcessExit) {
        if (event.exitCode == 0) {
          controller.emitLog(tag, 'Finished (exit 0)');
          state = const PrepStatus();
        } else {
          controller.emitLog(tag,
              'Exited with code ${event.exitCode}', isError: true);
          state = PrepStatus(
            lastError: 'Exit code ${event.exitCode}',
          );
        }
        _ref.invalidate(prepDoneProvider(task));
        _sub = null;
      }
    });
  }

  @override
  void dispose() {
    _sub?.cancel();
    super.dispose();
  }
}

final prepControllerProvider =
    StateNotifierProvider<PrepController, PrepStatus>((ref) {
  return PrepController(ref.watch(repoRootProvider), ref);
});
