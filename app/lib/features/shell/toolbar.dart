import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart' show MenuAnchor, MenuItemButton, Tooltip;
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
      height: 38,
      padding: const EdgeInsets.symmetric(horizontal: 12),
      decoration: BoxDecoration(
        color: CupertinoTheme.of(context).barBackgroundColor,
        border: const Border(
          bottom: BorderSide(color: CupertinoColors.separator, width: 0.5),
        ),
      ),
      child: Row(
        children: [
          const Icon(CupertinoIcons.cube_box, size: 14),
          const SizedBox(width: 6),
          envList.when(
            data: (envs) => _EnvPicker(
              envs: envs,
              active: activeEnvName.valueOrNull,
            ),
            loading: () => const CupertinoActivityIndicator(radius: 7),
            error: (_, __) => const Text(
              'No environment',
              style: TextStyle(
                fontSize: 13,
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

          const SizedBox(width: 12),

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
                size: 16,
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
}

class _EnvPicker extends ConsumerWidget {
  const _EnvPicker({required this.envs, required this.active});

  final List<String> envs;
  final String? active;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final labelColor = active != null
        ? CupertinoTheme.of(context).textTheme.textStyle.color
        : CupertinoColors.secondaryLabel;

    return MenuAnchor(
      alignmentOffset: const Offset(0, 4),
      menuChildren: [
        for (final name in envs)
          MenuItemButton(
            leadingIcon: Icon(
              name == active
                  ? CupertinoIcons.checkmark
                  : null,
              size: 13,
              color: CupertinoColors.activeBlue,
            ),
            onPressed: name == active
                ? null
                : () async {
                    final repo = ref.read(environmentRepositoryProvider);
                    await repo.setActiveEnvironment(name);
                  },
            child: Text(
              name,
              style: const TextStyle(fontSize: 13),
            ),
          ),
      ],
      builder: (context, controller, _) {
        return CupertinoButton(
          padding: EdgeInsets.zero,
          onPressed: envs.isEmpty
              ? null
              : () {
                  if (controller.isOpen) {
                    controller.close();
                  } else {
                    controller.open();
                  }
                },
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                active ?? 'No environment',
                style: TextStyle(fontSize: 13, color: labelColor),
              ),
              const SizedBox(width: 4),
              const Icon(
                CupertinoIcons.chevron_up_chevron_down,
                size: 10,
                color: CupertinoColors.secondaryLabel,
              ),
            ],
          ),
        );
      },
    );
  }
}
