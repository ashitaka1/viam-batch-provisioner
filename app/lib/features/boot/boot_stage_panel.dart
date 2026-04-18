import 'package:flutter/cupertino.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../models/service_status.dart';
import '../../providers/prep_providers.dart';
import '../../providers/service_providers.dart';

class BootStagePanel extends ConsumerWidget {
  const BootStagePanel({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final services = ref.watch(servicesControllerProvider);
    final log = ref.watch(serviceLogProvider).valueOrNull ?? const [];

    return Padding(
      padding: const EdgeInsets.all(24),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _Header(services: services),
          const SizedBox(height: 16),
          const _PrepRow(),
          const SizedBox(height: 16),
          _ServiceRow(
            label: 'HTTP server',
            detail: 'localhost:8234 — serves http-server/',
            status: services.http,
          ),
          const SizedBox(height: 8),
          _ServiceRow(
            label: 'dnsmasq',
            detail: 'proxy DHCP + TFTP on netboot/',
            status: services.dnsmasq,
          ),
          const SizedBox(height: 8),
          _ServiceRow(
            label: 'PXE watcher',
            detail: 'assigns names as machines boot',
            status: services.watcher,
          ),
          const SizedBox(height: 16),
          Row(
            children: [
              CupertinoButton.filled(
                padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 10),
                onPressed: services.anyBusy
                    ? null
                    : services.allRunning
                        ? () => ref
                            .read(servicesControllerProvider.notifier)
                            .stopAll()
                        : () => ref
                            .read(servicesControllerProvider.notifier)
                            .startAll(),
                child: Text(
                  services.allRunning ? 'Stop Services' : 'Start Services',
                ),
              ),
              const SizedBox(width: 12),
              if (services.anyBusy)
                const CupertinoActivityIndicator(radius: 9),
            ],
          ),
          const SizedBox(height: 16),
          Expanded(child: _ServiceLog(lines: log)),
        ],
      ),
    );
  }
}

class _Header extends StatelessWidget {
  const _Header({required this.services});
  final ServicesStatus services;

  @override
  Widget build(BuildContext context) {
    final running = services.allRunning;
    final anyUp = services.anyRunning;
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.only(right: 10, top: 2),
          child: Icon(
            running
                ? CupertinoIcons.antenna_radiowaves_left_right
                : anyUp
                    ? CupertinoIcons.exclamationmark_triangle
                    : CupertinoIcons.power,
            size: 22,
            color: running
                ? CupertinoColors.activeGreen
                : anyUp
                    ? CupertinoColors.systemOrange
                    : CupertinoColors.secondaryLabel,
          ),
        ),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                running
                    ? 'PXE services running'
                    : anyUp
                        ? 'PXE services partially up'
                        : 'PXE services stopped',
                style: const TextStyle(
                  fontSize: 20,
                  fontWeight: FontWeight.w600,
                ),
              ),
              const SizedBox(height: 2),
              const Text(
                'Boot a target machine from the network to assign names in arrival order.',
                style: TextStyle(
                  fontSize: 13,
                  color: CupertinoColors.secondaryLabel,
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }
}

class _PrepRow extends ConsumerWidget {
  const _PrepRow();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final prep = ref.watch(prepControllerProvider);
    final controller = ref.read(prepControllerProvider.notifier);

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      decoration: BoxDecoration(
        color: CupertinoColors.systemGrey6.resolveFrom(context),
        borderRadius: BorderRadius.circular(6),
      ),
      child: Row(
        children: [
          const Icon(
            CupertinoIcons.wrench,
            size: 16,
            color: CupertinoColors.secondaryLabel,
          ),
          const SizedBox(width: 10),
          const Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('PXE prep',
                    style: TextStyle(
                      fontSize: 13,
                      fontWeight: FontWeight.w600,
                    )),
                Text(
                  'One-time: extract GRUB + kernel, then stamp autoinstall config.',
                  style: TextStyle(
                    fontSize: 11,
                    color: CupertinoColors.secondaryLabel,
                  ),
                ),
              ],
            ),
          ),
          _PrepButton(
            label: 'Setup PXE',
            task: PrepTask.setupPxe,
            prep: prep,
            onRun: controller.run,
          ),
          const SizedBox(width: 8),
          _PrepButton(
            label: 'Build config',
            task: PrepTask.buildConfig,
            prep: prep,
            onRun: controller.run,
          ),
        ],
      ),
    );
  }
}

class _PrepButton extends StatelessWidget {
  const _PrepButton({
    required this.label,
    required this.task,
    required this.prep,
    required this.onRun,
  });
  final String label;
  final PrepTask task;
  final PrepStatus prep;
  final void Function(PrepTask) onRun;

  @override
  Widget build(BuildContext context) {
    final running = prep.isRunning(task);
    return CupertinoButton(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
      color: CupertinoColors.systemGrey5.resolveFrom(context),
      borderRadius: BorderRadius.circular(6),
      onPressed: prep.isBusy ? null : () => onRun(task),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (running) ...[
            const CupertinoActivityIndicator(radius: 7),
            const SizedBox(width: 6),
          ],
          Text(
            label,
            style: const TextStyle(
              fontSize: 12,
              color: CupertinoColors.label,
            ),
          ),
        ],
      ),
    );
  }
}

class _ServiceRow extends StatelessWidget {
  const _ServiceRow({
    required this.label,
    required this.detail,
    required this.status,
  });
  final String label;
  final String detail;
  final ServiceStatus status;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      decoration: BoxDecoration(
        color: CupertinoColors.systemGrey6.resolveFrom(context),
        borderRadius: BorderRadius.circular(6),
      ),
      child: Row(
        children: [
          _dot(status),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(label,
                    style: const TextStyle(
                      fontSize: 13,
                      fontWeight: FontWeight.w600,
                    )),
                Text(
                  status.message ?? detail,
                  style: TextStyle(
                    fontSize: 11,
                    color: status.state == ServiceState.error
                        ? CupertinoColors.systemRed
                        : CupertinoColors.secondaryLabel,
                  ),
                ),
              ],
            ),
          ),
          Text(
            _stateText(status.state),
            style: const TextStyle(
              fontSize: 11,
              color: CupertinoColors.tertiaryLabel,
            ),
          ),
        ],
      ),
    );
  }

  Widget _dot(ServiceStatus status) {
    final color = switch (status.state) {
      ServiceState.running => CupertinoColors.activeGreen,
      ServiceState.starting || ServiceState.stopping => CupertinoColors.systemYellow,
      ServiceState.error => CupertinoColors.systemRed,
      ServiceState.stopped => CupertinoColors.systemGrey3,
    };
    return Container(
      width: 10,
      height: 10,
      decoration: BoxDecoration(shape: BoxShape.circle, color: color),
    );
  }

  String _stateText(ServiceState s) => switch (s) {
        ServiceState.running => 'running',
        ServiceState.starting => 'starting',
        ServiceState.stopping => 'stopping',
        ServiceState.stopped => 'stopped',
        ServiceState.error => 'error',
      };
}

class _ServiceLog extends StatefulWidget {
  const _ServiceLog({required this.lines});
  final List<ServiceLogLine> lines;

  @override
  State<_ServiceLog> createState() => _ServiceLogState();
}

class _ServiceLogState extends State<_ServiceLog> {
  final _scroll = ScrollController();

  @override
  void didUpdateWidget(covariant _ServiceLog old) {
    super.didUpdateWidget(old);
    if (widget.lines.length != old.lines.length) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (_scroll.hasClients) {
          _scroll.jumpTo(_scroll.position.maxScrollExtent);
        }
      });
    }
  }

  @override
  void dispose() {
    _scroll.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (widget.lines.isEmpty) {
      return Container(
        decoration: BoxDecoration(
          color: CupertinoColors.systemGrey6.resolveFrom(context),
          borderRadius: BorderRadius.circular(6),
        ),
        alignment: Alignment.center,
        child: const Text(
          'No service output yet.',
          style: TextStyle(fontSize: 12, color: CupertinoColors.tertiaryLabel),
        ),
      );
    }
    return Container(
      decoration: BoxDecoration(
        color: CupertinoColors.systemGrey6.resolveFrom(context),
        borderRadius: BorderRadius.circular(6),
        border: Border.all(color: CupertinoColors.separator, width: 0.5),
      ),
      padding: const EdgeInsets.all(12),
      child: ListView.builder(
        controller: _scroll,
        itemCount: widget.lines.length,
        itemBuilder: (context, i) {
          final line = widget.lines[i];
          return Padding(
            padding: const EdgeInsets.symmetric(vertical: 1),
            child: Text.rich(
              TextSpan(children: [
                TextSpan(
                  text: '[${line.service}] ',
                  style: const TextStyle(
                    fontFamily: '.SF Mono',
                    fontSize: 11,
                    color: CupertinoColors.secondaryLabel,
                  ),
                ),
                TextSpan(
                  text: line.line,
                  style: TextStyle(
                    fontFamily: '.SF Mono',
                    fontSize: 11,
                    height: 1.3,
                    color: line.isError
                        ? CupertinoColors.systemRed.resolveFrom(context)
                        : CupertinoColors.label.resolveFrom(context),
                  ),
                ),
              ]),
            ),
          );
        },
      ),
    );
  }
}
