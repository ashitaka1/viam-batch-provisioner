import 'package:flutter/cupertino.dart' show CupertinoIcons;
import 'package:flutter/material.dart' show Tooltip;
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:macos_ui/macos_ui.dart';

import '../../models/service_status.dart';
import '../../providers/prep_providers.dart';
import '../../providers/service_providers.dart';
import '../../theme/theme.dart';

class BootStagePanel extends ConsumerWidget {
  const BootStagePanel({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final services = ref.watch(servicesControllerProvider);
    final log = ref.watch(serviceLogProvider).valueOrNull ?? const [];
    final setupDone =
        ref.watch(prepDoneProvider(PrepTask.setupPxe)).valueOrNull ?? false;
    final buildDone =
        ref.watch(prepDoneProvider(PrepTask.buildConfig)).valueOrNull ?? false;
    final prepReady = setupDone && buildDone;

    return Padding(
      padding: const EdgeInsets.all(24),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _Header(services: services),
          if (services.lastError != null) ...[
            const SizedBox(height: 12),
            _ErrorBanner(
              message: services.lastError!,
              onDismiss: () => ref
                  .read(servicesControllerProvider.notifier)
                  .clearLastError(),
            ),
          ],
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
              Tooltip(
                message: (services.allRunning || prepReady)
                    ? ''
                    : !setupDone
                        ? 'Run Setup PXE first'
                        : 'Run Build config first',
                waitDuration: const Duration(milliseconds: 400),
                child: PushButton(
                  controlSize: ControlSize.large,
                  onPressed: services.anyBusy
                      ? null
                      : services.allRunning
                          ? () => ref
                              .read(servicesControllerProvider.notifier)
                              .stopAll()
                          : prepReady
                              ? () => ref
                                  .read(servicesControllerProvider.notifier)
                                  .startAll()
                              : null,
                  child: Text(
                    services.allRunning ? 'Stop Services' : 'Start Services',
                  ),
                ),
              ),
              const SizedBox(width: 12),
              if (services.anyBusy) const ProgressCircle(radius: 9),
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
          child: MacosIcon(
            running
                ? CupertinoIcons.antenna_radiowaves_left_right
                : anyUp
                    ? CupertinoIcons.exclamationmark_triangle
                    : CupertinoIcons.power,
            size: 22,
            color: running
                ? MacosColors.systemGreenColor
                : anyUp
                    ? MacosColors.systemOrangeColor
                    : MacosColors.secondaryLabelColor,
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
                  color: MacosColors.secondaryLabelColor,
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }
}

class _ErrorBanner extends StatelessWidget {
  const _ErrorBanner({required this.message, required this.onDismiss});
  final String message;
  final VoidCallback onDismiss;

  @override
  Widget build(BuildContext context) {
    final textColor = MacosTheme.of(context).typography.body.color;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      decoration: BoxDecoration(
        color: MacosColors.systemRedColor.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(6),
        border: Border.all(
          color: MacosColors.systemRedColor.withValues(alpha: 0.4),
          width: 0.5,
        ),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const MacosIcon(
            CupertinoIcons.exclamationmark_triangle_fill,
            size: 16,
            color: MacosColors.systemRedColor,
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              message,
              style: TextStyle(
                fontSize: 12,
                color: textColor,
                height: 1.35,
              ),
            ),
          ),
          MacosIconButton(
            icon: const MacosIcon(
              CupertinoIcons.xmark,
              size: 12,
              color: MacosColors.secondaryLabelColor,
            ),
            boxConstraints: const BoxConstraints(
              minHeight: 20,
              minWidth: 20,
              maxHeight: 24,
              maxWidth: 24,
            ),
            onPressed: onDismiss,
          ),
        ],
      ),
    );
  }
}

class _PrepRow extends ConsumerWidget {
  const _PrepRow();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final prep = ref.watch(prepControllerProvider);
    final controller = ref.read(prepControllerProvider.notifier);
    final setupDone =
        ref.watch(prepDoneProvider(PrepTask.setupPxe)).valueOrNull ?? false;

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      decoration: BoxDecoration(
        color: MacosTheme.of(context).canvasColor,
        borderRadius: BorderRadius.circular(6),
        border: Border.all(
          color: MacosTheme.of(context).dividerColor,
          width: 0.5,
        ),
      ),
      child: Row(
        children: [
          const MacosIcon(
            CupertinoIcons.wrench,
            size: 16,
            color: MacosColors.secondaryLabelColor,
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
                    color: MacosColors.secondaryLabelColor,
                  ),
                ),
              ],
            ),
          ),
          _PrepButton(
            step: 1,
            label: 'Setup PXE',
            task: PrepTask.setupPxe,
            prep: prep,
            onRun: controller.run,
            disabledReason: null,
          ),
          const SizedBox(width: 8),
          _PrepButton(
            step: 2,
            label: 'Build config',
            task: PrepTask.buildConfig,
            prep: prep,
            onRun: controller.run,
            disabledReason: setupDone ? null : 'Run Setup PXE first',
          ),
        ],
      ),
    );
  }
}

class _PrepButton extends ConsumerWidget {
  const _PrepButton({
    required this.step,
    required this.label,
    required this.task,
    required this.prep,
    required this.onRun,
    required this.disabledReason,
  });
  final int step;
  final String label;
  final PrepTask task;
  final PrepStatus prep;
  final void Function(PrepTask) onRun;
  final String? disabledReason;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final running = prep.isRunning(task);
    final done = ref.watch(prepDoneProvider(task)).valueOrNull ?? false;
    final gated = disabledReason != null && !done;
    final enabled = !prep.isBusy && !gated;

    final button = PushButton(
      controlSize: ControlSize.small,
      secondary: !done,
      onPressed: enabled ? () => onRun(task) : null,
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (running)
            const ProgressCircle(radius: 7)
          else if (done)
            const MacosIcon(
              CupertinoIcons.checkmark_circle_fill,
              size: 13,
              color: MacosColors.systemGreenColor,
            )
          else
            const MacosIcon(
              CupertinoIcons.play_arrow_solid,
              size: 12,
              color: MacosColors.secondaryLabelColor,
            ),
          const SizedBox(width: 6),
          Text('$step. $label'),
        ],
      ),
    );

    if (gated) {
      return Tooltip(
        message: disabledReason!,
        waitDuration: const Duration(milliseconds: 400),
        child: button,
      );
    }
    return button;
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
        color: MacosTheme.of(context).canvasColor,
        borderRadius: BorderRadius.circular(6),
        border: Border.all(
          color: MacosTheme.of(context).dividerColor,
          width: 0.5,
        ),
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
                        ? MacosColors.systemRedColor
                        : MacosColors.secondaryLabelColor,
                  ),
                ),
              ],
            ),
          ),
          Text(
            _stateText(status.state),
            style: const TextStyle(
              fontSize: 11,
              color: MacosColors.tertiaryLabelColor,
            ),
          ),
        ],
      ),
    );
  }

  Widget _dot(ServiceStatus status) {
    final color = switch (status.state) {
      ServiceState.running => MacosColors.systemGreenColor,
      ServiceState.starting || ServiceState.stopping => MacosColors.systemYellowColor,
      ServiceState.error => MacosColors.systemRedColor,
      ServiceState.stopped => MacosColors.systemGrayColor,
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

  Future<void> _copy(BuildContext context) async {
    final text = widget.lines
        .map((l) => '[${l.service}] ${l.line}')
        .join('\n');
    await Clipboard.setData(ClipboardData(text: text));
  }

  @override
  Widget build(BuildContext context) {
    final bg = MacosTheme.of(context).canvasColor;
    final divider = MacosTheme.of(context).dividerColor;
    final textColor = MacosTheme.of(context).typography.body.color;

    if (widget.lines.isEmpty) {
      return Container(
        decoration: BoxDecoration(
          color: bg,
          borderRadius: BorderRadius.circular(6),
          border: Border.all(color: divider, width: 0.5),
        ),
        alignment: Alignment.center,
        child: const Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            MacosIcon(
              CupertinoIcons.square_list,
              size: 22,
              color: MacosColors.tertiaryLabelColor,
            ),
            SizedBox(height: 6),
            Text(
              'No service output yet.',
              style: TextStyle(
                fontSize: 12,
                color: MacosColors.tertiaryLabelColor,
              ),
            ),
          ],
        ),
      );
    }
    return Container(
      decoration: BoxDecoration(
        color: bg,
        borderRadius: BorderRadius.circular(6),
        border: Border.all(color: divider, width: 0.5),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 6, 4, 4),
            child: Row(
              children: [
                Text(
                  '${widget.lines.length} line${widget.lines.length == 1 ? '' : 's'}',
                  style: const TextStyle(
                    fontSize: 11,
                    color: MacosColors.tertiaryLabelColor,
                  ),
                ),
                const Spacer(),
                MacosIconButton(
                  icon: const Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      MacosIcon(
                        CupertinoIcons.doc_on_clipboard,
                        size: 12,
                        color: MacosColors.secondaryLabelColor,
                      ),
                      SizedBox(width: 4),
                      Text(
                        'Copy',
                        style: TextStyle(
                          fontSize: 11,
                          color: MacosColors.secondaryLabelColor,
                        ),
                      ),
                    ],
                  ),
                  boxConstraints: const BoxConstraints(
                    minHeight: 22,
                    minWidth: 22,
                    maxHeight: 28,
                    maxWidth: 80,
                  ),
                  onPressed: () => _copy(context),
                ),
              ],
            ),
          ),
          Container(height: 0.5, color: divider),
          Expanded(
            child: Padding(
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
                            fontFamilyFallback: monospaceFontFallback,
                            fontSize: 11,
                            color: MacosColors.secondaryLabelColor,
                          ),
                        ),
                        TextSpan(
                          text: line.line,
                          style: TextStyle(
                            fontFamilyFallback: monospaceFontFallback,
                            fontSize: 11,
                            height: 1.3,
                            color: line.isError
                                ? MacosColors.systemRedColor
                                : textColor,
                          ),
                        ),
                      ]),
                    ),
                  );
                },
              ),
            ),
          ),
        ],
      ),
    );
  }
}
