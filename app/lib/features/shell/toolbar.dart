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

          _ServicesMenu(services: services),

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

}

Color _serviceColor(ServiceState state) => switch (state) {
      ServiceState.running => CupertinoColors.activeGreen,
      ServiceState.starting ||
      ServiceState.stopping =>
        CupertinoColors.systemYellow,
      ServiceState.error => CupertinoColors.systemRed,
      ServiceState.stopped => CupertinoColors.systemGrey3,
    };

String _serviceStateLabel(ServiceState state) => switch (state) {
      ServiceState.running => 'running',
      ServiceState.starting => 'starting',
      ServiceState.stopping => 'stopping',
      ServiceState.error => 'error',
      ServiceState.stopped => 'stopped',
    };

class _ServicesMenu extends ConsumerWidget {
  const _ServicesMenu({required this.services});

  final ServicesStatus services;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final anyRunning = services.anyRunning;
    final anyBusy = services.anyBusy;

    return MenuAnchor(
      alignmentOffset: const Offset(0, 4),
      menuChildren: [
        _MenuHeader(services: services),
        Container(height: 0.5, color: CupertinoColors.separator),
        MenuItemButton(
          onPressed: anyBusy
              ? null
              : () {
                  ref.read(servicesControllerProvider.notifier).startAll();
                },
          leadingIcon: const Icon(
            CupertinoIcons.play_fill,
            size: 13,
            color: CupertinoColors.activeGreen,
          ),
          child: const Text(
            'Start all',
            style: TextStyle(fontSize: 13),
          ),
        ),
        MenuItemButton(
          onPressed: (!anyRunning || anyBusy)
              ? null
              : () {
                  ref.read(servicesControllerProvider.notifier).stopAll();
                },
          leadingIcon: const Icon(
            CupertinoIcons.stop_fill,
            size: 13,
            color: CupertinoColors.systemRed,
          ),
          child: const Text(
            'Stop all',
            style: TextStyle(fontSize: 13),
          ),
        ),
      ],
      builder: (context, controller, _) {
        return Tooltip(
          message:
              'PXE services — needed for x86 network boot. Click for controls.',
          waitDuration: const Duration(milliseconds: 500),
          child: CupertinoButton(
            padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 4),
            minSize: 0,
            onPressed: () {
              if (controller.isOpen) {
                controller.close();
              } else {
                controller.open();
              }
            },
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                _Dot(state: services.http.state),
                const SizedBox(width: 4),
                const Text(
                  'HTTP',
                  style: TextStyle(
                    fontSize: 11,
                    color: CupertinoColors.secondaryLabel,
                  ),
                ),
                const SizedBox(width: 8),
                _Dot(state: services.dnsmasq.state),
                const SizedBox(width: 4),
                const Text(
                  'DHCP',
                  style: TextStyle(
                    fontSize: 11,
                    color: CupertinoColors.secondaryLabel,
                  ),
                ),
                const SizedBox(width: 8),
                _Dot(state: services.watcher.state),
                const SizedBox(width: 4),
                const Text(
                  'Watch',
                  style: TextStyle(
                    fontSize: 11,
                    color: CupertinoColors.secondaryLabel,
                  ),
                ),
              ],
            ),
          ),
        );
      },
    );
  }
}

class _Dot extends StatelessWidget {
  const _Dot({required this.state});
  final ServiceState state;

  @override
  Widget build(BuildContext context) {
    return AnimatedContainer(
      duration: const Duration(milliseconds: 250),
      width: 8,
      height: 8,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        color: _serviceColor(state),
      ),
    );
  }
}

class _MenuHeader extends StatelessWidget {
  const _MenuHeader({required this.services});
  final ServicesStatus services;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(14, 10, 14, 10),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          const Text(
            'PXE services',
            style: TextStyle(
              fontSize: 11,
              fontWeight: FontWeight.w600,
              color: CupertinoColors.secondaryLabel,
            ),
          ),
          const SizedBox(height: 6),
          _serviceRow(
            'HTTP',
            services.http,
            subtitle: 'Embedded server on :8234',
          ),
          const SizedBox(height: 3),
          _serviceRow(
            'DHCP',
            services.dnsmasq,
            subtitle: 'dnsmasq proxy DHCP + TFTP',
          ),
          const SizedBox(height: 3),
          _serviceRow(
            'Watch',
            services.watcher,
            subtitle: 'Assigns names to MACs',
          ),
        ],
      ),
    );
  }

  Widget _serviceRow(
    String label,
    ServiceStatus status, {
    required String subtitle,
  }) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        _Dot(state: status.state),
        const SizedBox(width: 8),
        SizedBox(
          width: 52,
          child: Text(
            label,
            style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w600),
          ),
        ),
        SizedBox(
          width: 60,
          child: Text(
            _serviceStateLabel(status.state),
            style: const TextStyle(
              fontSize: 11,
              color: CupertinoColors.secondaryLabel,
            ),
          ),
        ),
        Text(
          subtitle,
          style: const TextStyle(
            fontSize: 11,
            color: CupertinoColors.tertiaryLabel,
          ),
        ),
      ],
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
