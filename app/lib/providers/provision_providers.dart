import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path/path.dart' as p;

import '../core/process_runner.dart';
import '../core/repo_root.dart';
import '../models/batch.dart';

class ProvisionSession {
  const ProvisionSession({
    this.lines = const [],
    this.isRunning = false,
    this.exitCode,
    this.startedAt,
  });

  final List<ProcessLine> lines;
  final bool isRunning;
  final int? exitCode;
  final DateTime? startedAt;

  bool get hasRun => startedAt != null;
  bool get succeeded => exitCode == 0;

  ProvisionSession copyWith({
    List<ProcessLine>? lines,
    bool? isRunning,
    int? exitCode,
    DateTime? startedAt,
  }) {
    return ProvisionSession(
      lines: lines ?? this.lines,
      isRunning: isRunning ?? this.isRunning,
      exitCode: exitCode ?? this.exitCode,
      startedAt: startedAt ?? this.startedAt,
    );
  }
}

class ProvisionController extends StateNotifier<ProvisionSession> {
  ProvisionController(this._repoRoot) : super(const ProvisionSession());

  final String _repoRoot;
  StreamSubscription<ProcessEvent>? _sub;

  Future<void> run({
    required String prefix,
    required int count,
    required BatchTargetType targetType,
  }) async {
    if (state.isRunning) return;
    await _sub?.cancel();

    state = ProvisionSession(
      lines: const [],
      isRunning: true,
      startedAt: DateTime.now(),
    );

    final script = p.join(_repoRoot, 'cli', 'provision-batch.sh');
    final args = ['--prefix', prefix, '--count', '$count'];

    _sub = runProcess(
      executable: script,
      arguments: args,
      workingDirectory: _repoRoot,
    ).listen((event) {
      if (event is ProcessLine) {
        state = state.copyWith(lines: [...state.lines, event]);
      } else if (event is ProcessExit) {
        state = state.copyWith(isRunning: false, exitCode: event.exitCode);
      }
    });
  }

  void reset() {
    _sub?.cancel();
    state = const ProvisionSession();
  }

  @override
  void dispose() {
    _sub?.cancel();
    super.dispose();
  }
}

final provisionControllerProvider =
    StateNotifierProvider<ProvisionController, ProvisionSession>((ref) {
  return ProvisionController(ref.watch(repoRootProvider));
});
