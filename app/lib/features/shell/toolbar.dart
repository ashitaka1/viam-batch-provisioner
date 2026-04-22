import 'package:flutter/cupertino.dart' show CupertinoIcons;
import 'package:flutter/material.dart' show MenuAnchor, MenuItemButton, Tooltip;
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:macos_ui/macos_ui.dart';

import '../../models/service_status.dart';
import '../../providers/environment_providers.dart';
import '../../providers/service_providers.dart';
import 'app_shell.dart';

ToolBar buildAppToolBar(BuildContext context, WidgetRef ref) {
  return ToolBar(
    title: const Text('Viam Provisioner'),
    titleWidth: 180,
    padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
    actions: [
      CustomToolbarItem(
        inToolbarBuilder: (context) => const _EnvSection(),
      ),
      const ToolBarSpacer(),
      CustomToolbarItem(
        inToolbarBuilder: (context) => const _ServicesSection(),
      ),
      CustomToolbarItem(
        inToolbarBuilder: (context) => const _SettingsButton(),
      ),
    ],
  );
}

class _EnvSection extends ConsumerWidget {
  const _EnvSection();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final envList = ref.watch(environmentListProvider);
    final activeEnvName = ref.watch(activeEnvironmentNameProvider);
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        const MacosIcon(CupertinoIcons.cube_box, size: 14),
        const SizedBox(width: 6),
        envList.when(
          data: (envs) => _EnvPicker(
            envs: envs,
            active: activeEnvName.valueOrNull,
          ),
          loading: () => const ProgressCircle(radius: 7),
          error: (_, __) => const Text(
            'No environment',
            style: TextStyle(
              fontSize: 13,
              color: MacosColors.secondaryLabelColor,
            ),
          ),
        ),
      ],
    );
  }
}

class _ServicesSection extends ConsumerWidget {
  const _ServicesSection();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final services = ref.watch(servicesControllerProvider);
    return _ServicesMenu(services: services);
  }
}

class _SettingsButton extends ConsumerWidget {
  const _SettingsButton();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final settingsOpen = ref.watch(settingsOpenProvider);
    return Padding(
      padding: const EdgeInsets.only(left: 8),
      child: MacosIconButton(
        icon: MacosIcon(
          settingsOpen ? CupertinoIcons.gear_solid : CupertinoIcons.gear,
          size: 16,
        ),
        onPressed: () {
          ref.read(settingsOpenProvider.notifier).state = !settingsOpen;
        },
      ),
    );
  }
}

Color _serviceColor(ServiceState state) => switch (state) {
      ServiceState.running => MacosColors.systemGreenColor,
      ServiceState.starting ||
      ServiceState.stopping =>
        MacosColors.systemYellowColor,
      ServiceState.error => MacosColors.systemRedColor,
      ServiceState.stopped => MacosColors.systemGrayColor,
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
        Container(height: 0.5, color: MacosTheme.of(context).dividerColor),
        MenuItemButton(
          onPressed: anyBusy
              ? null
              : () {
                  ref.read(servicesControllerProvider.notifier).startAll();
                },
          leadingIcon: const MacosIcon(
            CupertinoIcons.play_fill,
            size: 13,
            color: MacosColors.systemGreenColor,
          ),
          child: const Text('Start all', style: TextStyle(fontSize: 13)),
        ),
        MenuItemButton(
          onPressed: (!anyRunning || anyBusy)
              ? null
              : () {
                  ref.read(servicesControllerProvider.notifier).stopAll();
                },
          leadingIcon: const MacosIcon(
            CupertinoIcons.stop_fill,
            size: 13,
            color: MacosColors.systemRedColor,
          ),
          child: const Text('Stop all', style: TextStyle(fontSize: 13)),
        ),
      ],
      builder: (context, controller, _) {
        return Tooltip(
          message:
              'PXE services — needed for x86 network boot. Click for controls.',
          waitDuration: const Duration(milliseconds: 500),
          child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: () {
              if (controller.isOpen) {
                controller.close();
              } else {
                controller.open();
              }
            },
            child: Padding(
              padding:
                  const EdgeInsets.symmetric(horizontal: 6, vertical: 4),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  _Dot(state: services.http.state),
                  const SizedBox(width: 4),
                  const Text(
                    'HTTP',
                    style: TextStyle(
                      fontSize: 11,
                      color: MacosColors.secondaryLabelColor,
                    ),
                  ),
                  const SizedBox(width: 8),
                  _Dot(state: services.dnsmasq.state),
                  const SizedBox(width: 4),
                  const Text(
                    'DHCP',
                    style: TextStyle(
                      fontSize: 11,
                      color: MacosColors.secondaryLabelColor,
                    ),
                  ),
                  const SizedBox(width: 8),
                  _Dot(state: services.watcher.state),
                  const SizedBox(width: 4),
                  const Text(
                    'Watch',
                    style: TextStyle(
                      fontSize: 11,
                      color: MacosColors.secondaryLabelColor,
                    ),
                  ),
                ],
              ),
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
              color: MacosColors.secondaryLabelColor,
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
              color: MacosColors.secondaryLabelColor,
            ),
          ),
        ),
        Text(
          subtitle,
          style: const TextStyle(
            fontSize: 11,
            color: MacosColors.tertiaryLabelColor,
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
        ? MacosTheme.of(context).typography.body.color
        : MacosColors.secondaryLabelColor;

    return MenuAnchor(
      alignmentOffset: const Offset(0, 4),
      menuChildren: [
        for (final name in envs)
          MenuItemButton(
            leadingIcon: MacosIcon(
              name == active ? CupertinoIcons.checkmark : null,
              size: 13,
              color: MacosColors.controlAccentColor,
            ),
            onPressed: name == active
                ? null
                : () async {
                    final repo = ref.read(environmentRepositoryProvider);
                    await repo.setActiveEnvironment(name);
                  },
            child: Text(name, style: const TextStyle(fontSize: 13)),
          ),
      ],
      builder: (context, controller, _) {
        return GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: envs.isEmpty
              ? null
              : () {
                  if (controller.isOpen) {
                    controller.close();
                  } else {
                    controller.open();
                  }
                },
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 4),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  active ?? 'No environment',
                  style: TextStyle(fontSize: 13, color: labelColor),
                ),
                const SizedBox(width: 4),
                const MacosIcon(
                  CupertinoIcons.chevron_up_chevron_down,
                  size: 10,
                  color: MacosColors.secondaryLabelColor,
                ),
              ],
            ),
          ),
        );
      },
    );
  }
}
