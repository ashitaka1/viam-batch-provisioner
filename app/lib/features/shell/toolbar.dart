import 'package:flutter/cupertino.dart';
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

          _serviceIndicator('HTTP', services.http),
          const SizedBox(width: 8),
          _serviceIndicator('DHCP', services.dnsmasq),
          const SizedBox(width: 8),
          _serviceIndicator('Watch', services.watcher),

          const SizedBox(width: 16),

          // Settings gear
          CupertinoButton(
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
        ],
      ),
    );
  }

  Widget _serviceIndicator(String label, ServiceStatus status) {
    final color = switch (status.state) {
      ServiceState.running => CupertinoColors.activeGreen,
      ServiceState.starting ||
      ServiceState.stopping =>
        CupertinoColors.systemYellow,
      ServiceState.error => CupertinoColors.systemRed,
      ServiceState.stopped => CupertinoColors.systemGrey3,
    };
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Container(
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
