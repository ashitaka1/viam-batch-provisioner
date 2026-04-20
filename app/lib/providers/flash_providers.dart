import 'dart:async';
import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path/path.dart' as p;

import '../core/disk_utils.dart';
import '../core/platform_utils.dart';
import '../core/process_runner.dart';
import '../core/repo_root.dart';
import '../models/flash_state.dart';
import 'queue_providers.dart';

class FlashController extends StateNotifier<FlashState> {
  FlashController(this._repoRoot, this._ref) : super(const FlashState());

  final String _repoRoot;
  final Ref _ref;
  List<DiskInfo> _baselineDisks = const [];
  ProcessHandle? _flashHandle;
  StreamSubscription<ProcessEvent>? _flashSub;
  Timer? _pollTimer;

  /// Begin the flash flow for [machineName]. Snapshots currently-attached
  /// disks so new ones can be detected by diff.
  Future<void> begin(String machineName) async {
    await _cancelPoll();
    _baselineDisks = await listExternalDisks();
    state = FlashState(
      phase: FlashPhase.awaitInsert,
      machineName: machineName,
      flashedNames: state.flashedNames,
    );
    _startPoll();
  }

  /// Rescan external disks on demand (e.g. user clicked "Detect again").
  Future<void> rescan() async {
    final after = await listExternalDisks();
    final newOnes = diffDisks(_baselineDisks, after);
    _applyDetection(newOnes);
  }

  void _startPoll() {
    _pollTimer?.cancel();
    _pollTimer = Timer.periodic(const Duration(seconds: 2), (_) async {
      if (state.phase != FlashPhase.awaitInsert) return;
      final after = await listExternalDisks();
      final newOnes = diffDisks(_baselineDisks, after);
      if (newOnes.isNotEmpty) _applyDetection(newOnes);
    });
  }

  void _applyDetection(List<DiskInfo> newOnes) {
    if (newOnes.isEmpty) {
      state = state.copyWith(
        clearDisk: true,
        candidateDisks: const [],
        phase: FlashPhase.awaitInsert,
      );
      _startPoll();
      return;
    }
    _pollTimer?.cancel();
    if (newOnes.length == 1) {
      state = state.copyWith(
        phase: FlashPhase.detected,
        detectedDisk: newOnes.first,
        candidateDisks: const [],
      );
    } else {
      state = state.copyWith(
        phase: FlashPhase.choose,
        candidateDisks: newOnes,
        clearDisk: true,
      );
    }
  }

  /// Operator picked a specific disk from the multi-detected chooser.
  void pickCandidate(DiskInfo disk) {
    state = state.copyWith(
      phase: FlashPhase.detected,
      detectedDisk: disk,
      candidateDisks: const [],
    );
  }

  Future<void> _cancelPoll() async {
    _pollTimer?.cancel();
    _pollTimer = null;
  }

  /// Writes the Pi image to the detected disk via cli/flash-pi-sd.sh.
  /// Requires a prior [acquireSudo]. Streams dd progress into [state.progressLines].
  Future<void> flash() async {
    final disk = state.detectedDisk;
    final name = state.machineName;
    if (disk == null || name == null) return;

    final ok = await acquireSudo();
    if (!ok) {
      state = state.copyWith(
        phase: FlashPhase.error,
        error: 'Sudo authentication cancelled',
      );
      return;
    }

    state = state.copyWith(
      phase: FlashPhase.flashing,
      progressLines: const [],
      clearError: true,
    );

    final script = p.join(_repoRoot, 'cli', 'flash-pi-sd.sh');
    final handle = await startProcess(
      executable: script,
      arguments: ['--yes', disk.device, name],
      workingDirectory: _repoRoot,
    );
    _flashHandle = handle;
    _flashSub = handle.events.listen((event) async {
      if (event is ProcessLine) {
        state = state.copyWith(
          progressLines: [...state.progressLines, event.line],
        );
      } else if (event is ProcessExit) {
        if (event.exitCode == 0) {
          await _ref.read(queueRepositoryProvider).markAssigned(name);
          state = state.copyWith(
            phase: FlashPhase.done,
            flashedNames: [...state.flashedNames, name],
          );
        } else if (state.phase != FlashPhase.idle) {
          // Non-zero exit that wasn't already folded into the cancel path.
          state = state.copyWith(
            phase: FlashPhase.error,
            error: 'flash-pi-sd.sh exited with code ${event.exitCode}',
          );
        }
        _flashHandle = null;
        _flashSub = null;
      }
    });
  }

  /// Returns to idle so the operator can choose the next machine.
  void finish() {
    state = FlashState(flashedNames: state.flashedNames);
  }

  Future<void> cancel() async {
    // Kill the child script first. Its sudo'd `dd` child is not
    // automatically killed by signalling the shell parent, so chase
    // it with a scoped `sudo -n pkill` as belt-and-suspenders.
    final handle = _flashHandle;
    if (handle != null) {
      handle.kill();
      final disk = state.detectedDisk?.device;
      if (disk != null) {
        // Kill the dd that's writing to this specific device. The -n flag
        // requires a prior sudo unlock (we have one from flash()).
        unawaited(Process.run(
          '/usr/bin/sudo',
          ['-n', '/usr/bin/pkill', '-TERM', '-f', 'dd if=.* of=$disk'],
        ));
      }
    }
    await _flashSub?.cancel();
    _flashSub = null;
    _flashHandle = null;
    _pollTimer?.cancel();
    state = FlashState(flashedNames: state.flashedNames);
  }

  @override
  void dispose() {
    _flashHandle?.kill();
    _flashSub?.cancel();
    _pollTimer?.cancel();
    super.dispose();
  }
}

final flashControllerProvider =
    StateNotifierProvider<FlashController, FlashState>((ref) {
  return FlashController(ref.watch(repoRootProvider), ref);
});
