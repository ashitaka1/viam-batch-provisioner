import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart' show Tooltip;
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../models/service_status.dart';
import '../../providers/environment_providers.dart';
import '../../providers/service_providers.dart';
import 'app_shell.dart';

class Toolbar extends ConsumerWidget {
  const Toolbar({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final envList = ref.watch(environmentListProvider);
    final activeEnvName = ref.watch(activeEnvironmentNameProvider);
    final settingsOpen = ref.watch(settingsOpenProvider);
    final services = ref.watch(servicesControllerProvider);

    return Container(
      height: 52,
      padding: const EdgeInsets.symmetric(horizontal: 16),
      decoration: BoxDecoration(
        color: CupertinoTheme.of(context).barBackgroundColor,
        border: const Border(
          bottom: BorderSide(color: CupertinoColors.separator, width: 0.5),
        ),
      ),
      child: Row(
        children: [
          // Environment dropdown
          const Icon(CupertinoIcons.doc_text, size: 16),
          const SizedBox(width: 8),
          envList.when(
            data: (envs) {
              final active = activeEnvName.valueOrNull;
              return CupertinoButton(
                padding: EdgeInsets.zero,
                onPressed: envs.isEmpty
                    ? null
                    : () => _showEnvPicker(context, ref, envs, active),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      active ?? 'No environment',
                      style: TextStyle(
                        fontSize: 14,
                        color: active != null
                            ? CupertinoTheme.of(context)
                                .textTheme
                                .textStyle
                                .color
                            : CupertinoColors.secondaryLabel,
                      ),
                    ),
                    const SizedBox(width: 4),
                    const Icon(CupertinoIcons.chevron_down,
                        size: 12, color: CupertinoColors.secondaryLabel),
                  ],
                ),
              );
            },
            loading: () => const CupertinoActivityIndicator(radius: 8),
            error: (_, __) => const Text(
              'No environment',
              style: TextStyle(
                fontSize: 14,
                color: CupertinoColors.secondaryLabel,
              ),
            ),
          ),

          const Spacer(),

          _serviceIndicator('HTTP', services.http,
              tooltip: 'Embedded HTTP server (port 8234)'),
          const SizedBox(width: 8),
          _serviceIndicator('DHCP', services.dnsmasq,
              tooltip: 'dnsmasq proxy DHCP + TFTP'),
          const SizedBox(width: 8),
          _serviceIndicator('Watch', services.watcher,
              tooltip: 'PXE watcher — assigns names to MACs as machines boot'),

          const SizedBox(width: 16),

          // Settings gear
          Tooltip(
            message: 'Settings',
            waitDuration: const Duration(milliseconds: 500),
            child: CupertinoButton(
              padding: EdgeInsets.zero,
              onPressed: () {
                ref.read(settingsOpenProvider.notifier).state = !settingsOpen;
              },
              child: Icon(
                settingsOpen
                    ? CupertinoIcons.gear_solid
                    : CupertinoIcons.gear,
                size: 22,
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _serviceIndicator(
    String label,
    ServiceStatus status, {
    required String tooltip,
  }) {
    final color = switch (status.state) {
      ServiceState.running => CupertinoColors.activeGreen,
      ServiceState.starting ||
      ServiceState.stopping =>
        CupertinoColors.systemYellow,
      ServiceState.error => CupertinoColors.systemRed,
      ServiceState.stopped => CupertinoColors.systemGrey3,
    };
    final stateLabel = switch (status.state) {
      ServiceState.running => 'running',
      ServiceState.starting => 'starting',
      ServiceState.stopping => 'stopping',
      ServiceState.error => 'error',
      ServiceState.stopped => 'stopped',
    };
    return Tooltip(
      message: '$tooltip — $stateLabel',
      waitDuration: const Duration(milliseconds: 500),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          AnimatedContainer(
            duration: const Duration(milliseconds: 250),
            width: 8,
            height: 8,
            decoration: BoxDecoration(shape: BoxShape.circle, color: color),
          ),
          const SizedBox(width: 4),
          Text(
            label,
            style: const TextStyle(
              fontSize: 11,
              color: CupertinoColors.secondaryLabel,
            ),
          ),
        ],
      ),
    );
  }

  void _showEnvPicker(
    BuildContext context,
    WidgetRef ref,
    List<String> envs,
    String? active,
  ) {
    showCupertinoModalPopup(
      context: context,
      builder: (ctx) => CupertinoActionSheet(
        title: const Text('Switch Environment'),
        actions: envs
            .map(
              (name) => CupertinoActionSheetAction(
                isDefaultAction: name == active,
                onPressed: () async {
                  final repo = ref.read(environmentRepositoryProvider);
                  await repo.setActiveEnvironment(name);
                  if (ctx.mounted) Navigator.pop(ctx);
                },
                child: Text(name),
              ),
            )
            .toList(),
        cancelButton: CupertinoActionSheetAction(
          isDestructiveAction: true,
          onPressed: () => Navigator.pop(ctx),
          child: const Text('Cancel'),
        ),
      ),
    );
  }
}
