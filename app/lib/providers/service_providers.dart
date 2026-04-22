import 'dart:async';
import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path/path.dart' as p;

import '../core/http_server.dart';
import '../core/platform_utils.dart';
import '../core/process_runner.dart';
import '../core/repo_root.dart';
import '../models/service_status.dart';
import 'preferences_providers.dart';

class ServiceLogLine {
  const ServiceLogLine(this.service, this.line, {this.isError = false});
  final String service;
  final String line;
  final bool isError;
}

class ServicesController extends StateNotifier<ServicesStatus> {
  ServicesController(this._repoRoot, {required this.getWatcherInterface})
      : super(const ServicesStatus());

  final String _repoRoot;
  final String? Function() getWatcherInterface;
  EmbeddedHttpServer? _httpServer;
  StreamSubscription<ProcessEvent>? _dnsmasqSub;
  StreamSubscription<ProcessEvent>? _watcherSub;

  final _log = StreamController<ServiceLogLine>.broadcast();
  Stream<ServiceLogLine> get log => _log.stream;

  /// Appends an arbitrary line to the shared service log. Used by prep
  /// tasks (setup-pxe-server, build-config) that share this log view.
  void emitLog(String tag, String line, {bool isError = false}) {
    _log.add(ServiceLogLine(tag, line, isError: isError));
  }

  void clearLastError() {
    if (state.lastError == null) return;
    state = state.copyWith(clearLastError: true);
  }

  Future<void> startAll() async {
    if (state.anyBusy) return;
    state = state.copyWith(clearLastError: true);

    final sudoOk = await acquireSudo();
    if (!sudoOk) {
      state = state.copyWith(
        lastError:
            'Sudo authentication cancelled — dnsmasq and the PXE watcher need root to bind.',
      );
      _log.add(const ServiceLogLine(
        'services',
        'Start cancelled: sudo authentication declined.',
        isError: true,
      ));
      return;
    }

    await _startHttp();
    await _startDnsmasq();
    await _startWatcher();
  }

  Future<void> stopAll() async {
    state = state.copyWith(clearLastError: true);
    await _stopWatcher();
    await _stopDnsmasq();
    await _stopHttp();
  }

  Future<void> _startHttp() async {
    if (_httpServer != null) return;
    state = state.copyWith(
      http: const ServiceStatus(state: ServiceState.starting),
    );
    try {
      final docRoot = p.join(_repoRoot, 'http-server');
      final server = EmbeddedHttpServer(docRoot: docRoot);
      await server.start();
      _httpServer = server;
      server.requests.listen((line) {
        _log.add(ServiceLogLine('http', line));
      });
      state = state.copyWith(
        http: const ServiceStatus(state: ServiceState.running),
      );
      _log.add(ServiceLogLine('http', 'Listening on :8234'));
    } catch (e) {
      state = state.copyWith(
        http: ServiceStatus(state: ServiceState.error, message: '$e'),
      );
      _log.add(ServiceLogLine('http', '$e', isError: true));
    }
  }

  Future<void> _stopHttp() async {
    final server = _httpServer;
    if (server == null) return;
    state = state.copyWith(
      http: const ServiceStatus(state: ServiceState.stopping),
    );
    await server.stop();
    _httpServer = null;
    state = state.copyWith(http: ServiceStatus.stopped);
    _log.add(const ServiceLogLine('http', 'Stopped'));
  }

  Future<void> _startDnsmasq() async {
    if (_dnsmasqSub != null) return;
    state = state.copyWith(
      dnsmasq: const ServiceStatus(state: ServiceState.starting),
    );
    _dnsmasqSub = startPrivileged(
      executable: 'dnsmasq',
      arguments: [
        '--conf-file=${p.join(_repoRoot, 'netboot', 'dnsmasq.conf')}',
        '--tftp-root=${p.join(_repoRoot, 'netboot')}',
        '--log-facility=${p.join(_repoRoot, 'dnsmasq.log')}',
        '--no-daemon',
      ],
      workingDirectory: _repoRoot,
    ).listen((event) {
      if (event is ProcessLine) {
        _log.add(ServiceLogLine('dnsmasq', event.line, isError: event.isError));
      } else if (event is ProcessExit) {
        state = state.copyWith(
          dnsmasq: event.exitCode == 0
              ? ServiceStatus.stopped
              : ServiceStatus(
                  state: ServiceState.error,
                  message: 'Exited with code ${event.exitCode}',
                ),
        );
        _dnsmasqSub = null;
      }
    });
    // dnsmasq in foreground — if it doesn't exit in 500ms, consider it up.
    await Future.delayed(const Duration(milliseconds: 500));
    if (_dnsmasqSub != null &&
        state.dnsmasq.state == ServiceState.starting) {
      state = state.copyWith(
        dnsmasq: const ServiceStatus(state: ServiceState.running),
      );
    }
  }

  Future<void> _stopDnsmasq() async {
    if (_dnsmasqSub == null) return;
    state = state.copyWith(
      dnsmasq: const ServiceStatus(state: ServiceState.stopping),
    );
    await Process.run('/usr/bin/sudo', ['-n', '/usr/bin/killall', 'dnsmasq']);
    await _dnsmasqSub?.cancel();
    _dnsmasqSub = null;
    state = state.copyWith(dnsmasq: ServiceStatus.stopped);
  }

  Future<void> _startWatcher() async {
    if (_watcherSub != null) return;
    state = state.copyWith(
      watcher: const ServiceStatus(state: ServiceState.starting),
    );
    final python = p.join(_repoRoot, '.venv', 'bin', 'python3');
    final script = p.join(_repoRoot, 'pxe-watcher', 'watcher.py');
    final iface = getWatcherInterface();
    _watcherSub = startPrivileged(
      executable: python,
      arguments: [
        script,
        if (iface != null) ...['--interface', iface],
      ],
      workingDirectory: _repoRoot,
    ).listen((event) {
      if (event is ProcessLine) {
        _log.add(ServiceLogLine('watcher', event.line, isError: event.isError));
      } else if (event is ProcessExit) {
        state = state.copyWith(
          watcher: event.exitCode == 0
              ? ServiceStatus.stopped
              : ServiceStatus(
                  state: ServiceState.error,
                  message: 'Exited with code ${event.exitCode}',
                ),
        );
        _watcherSub = null;
      }
    });
    await Future.delayed(const Duration(milliseconds: 500));
    if (_watcherSub != null &&
        state.watcher.state == ServiceState.starting) {
      state = state.copyWith(
        watcher: const ServiceStatus(state: ServiceState.running),
      );
    }
  }

  Future<void> _stopWatcher() async {
    if (_watcherSub == null) return;
    state = state.copyWith(
      watcher: const ServiceStatus(state: ServiceState.stopping),
    );
    await Process.run(
      '/usr/bin/sudo',
      ['-n', '/usr/bin/pkill', '-f', 'pxe-watcher/watcher.py'],
    );
    await _watcherSub?.cancel();
    _watcherSub = null;
    state = state.copyWith(watcher: ServiceStatus.stopped);
  }

  @override
  void dispose() {
    stopAll();
    _log.close();
    super.dispose();
  }
}

final servicesControllerProvider =
    StateNotifierProvider<ServicesController, ServicesStatus>((ref) {
  return ServicesController(
    ref.watch(repoRootProvider),
    getWatcherInterface: () => ref.read(selectedNetworkInterfaceProvider),
  );
});

final serviceLogProvider = StreamProvider<List<ServiceLogLine>>((ref) async* {
  final controller = ref.watch(servicesControllerProvider.notifier);
  final buffer = <ServiceLogLine>[];
  yield buffer;
  await for (final line in controller.log) {
    buffer.add(line);
    if (buffer.length > 500) buffer.removeRange(0, buffer.length - 500);
    yield List.unmodifiable(buffer);
  }
});
