import 'package:flutter/cupertino.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../providers/environment_providers.dart';
import '../../providers/preferences_providers.dart';
import 'environment_form.dart';

class SettingsDrawer extends ConsumerWidget {
  const SettingsDrawer({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return Container(
      color: CupertinoTheme.of(context).barBackgroundColor,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          // Header
          Container(
            padding: const EdgeInsets.all(16),
            decoration: const BoxDecoration(
              border: Border(
                bottom:
                    BorderSide(color: CupertinoColors.separator, width: 0.5),
              ),
            ),
            child: const Text(
              'Settings',
              style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
            ),
          ),

          // Environments section
          Expanded(
            child: _EnvironmentSection(),
          ),

          Container(height: 0.5, color: CupertinoColors.separator),
          const _AppearanceSection(),
          Container(height: 0.5, color: CupertinoColors.separator),
          const _NetworkSection(),
        ],
      ),
    );
  }
}

class _AppearanceSection extends ConsumerWidget {
  const _AppearanceSection();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final mode = ref.watch(themeModeProvider);
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 14, 16, 14),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text(
            'Appearance',
            style: TextStyle(
              fontSize: 13,
              fontWeight: FontWeight.w600,
              color: CupertinoColors.secondaryLabel,
            ),
          ),
          const SizedBox(height: 8),
          CupertinoSlidingSegmentedControl<AppThemeMode>(
            groupValue: mode,
            onValueChanged: (value) {
              if (value == null) return;
              ref.read(themeModeProvider.notifier).state = value;
            },
            children: const {
              AppThemeMode.system: Padding(
                padding: EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                child: Text('System', style: TextStyle(fontSize: 12)),
              ),
              AppThemeMode.light: Padding(
                padding: EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                child: Text('Light', style: TextStyle(fontSize: 12)),
              ),
              AppThemeMode.dark: Padding(
                padding: EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                child: Text('Dark', style: TextStyle(fontSize: 12)),
              ),
            },
          ),
        ],
      ),
    );
  }
}

class _NetworkSection extends ConsumerWidget {
  const _NetworkSection();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final interfaces = ref.watch(networkInterfacesProvider);
    final defaultIface = ref.watch(defaultNetworkInterfaceProvider);
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 14, 16, 16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text(
            'Network',
            style: TextStyle(
              fontSize: 13,
              fontWeight: FontWeight.w600,
              color: CupertinoColors.secondaryLabel,
            ),
          ),
          const SizedBox(height: 6),
          interfaces.when(
            data: (list) => Text(
              list.isEmpty
                  ? 'No interfaces detected'
                  : list.join(' · '),
              style: const TextStyle(
                fontSize: 11,
                fontFamily: '.SF Mono',
                color: CupertinoColors.secondaryLabel,
              ),
            ),
            loading: () => const CupertinoActivityIndicator(radius: 7),
            error: (e, _) => Text(
              '$e',
              style: const TextStyle(
                fontSize: 11,
                color: CupertinoColors.systemRed,
              ),
            ),
          ),
          const SizedBox(height: 4),
          defaultIface.when(
            data: (iface) => Text(
              iface == null
                  ? 'No ethernet / thunderbolt interface detected'
                  : 'Default: $iface',
              style: const TextStyle(
                fontSize: 11,
                color: CupertinoColors.tertiaryLabel,
              ),
            ),
            loading: () => const SizedBox.shrink(),
            error: (_, __) => const SizedBox.shrink(),
          ),
        ],
      ),
    );
  }
}

class _EnvironmentSection extends ConsumerWidget {
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final envList = ref.watch(environmentListProvider);
    final activeEnvName = ref.watch(activeEnvironmentNameProvider);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
          child: Row(
            children: [
              const Text(
                'Environments',
                style: TextStyle(
                  fontSize: 13,
                  fontWeight: FontWeight.w600,
                  color: CupertinoColors.secondaryLabel,
                ),
              ),
              const Spacer(),
              CupertinoButton(
                padding: EdgeInsets.zero,
                minSize: 24,
                onPressed: () => _showCreateDialog(context, ref),
                child: const Icon(CupertinoIcons.plus, size: 18),
              ),
            ],
          ),
        ),
        Expanded(
          child: envList.when(
            data: (envs) {
              if (envs.isEmpty) {
                return const Center(
                  child: Padding(
                    padding: EdgeInsets.all(16),
                    child: Text(
                      'No environments yet.\nTap + to create one.',
                      textAlign: TextAlign.center,
                      style: TextStyle(
                        color: CupertinoColors.tertiaryLabel,
                        fontSize: 13,
                      ),
                    ),
                  ),
                );
              }
              final active = activeEnvName.valueOrNull;
              return ListView.builder(
                padding: const EdgeInsets.symmetric(horizontal: 8),
                itemCount: envs.length,
                itemBuilder: (ctx, i) {
                  final name = envs[i];
                  final isActive = name == active;
                  return _EnvironmentTile(
                    name: name,
                    isActive: isActive,
                  );
                },
              );
            },
            loading: () =>
                const Center(child: CupertinoActivityIndicator()),
            error: (e, _) => Center(child: Text('Error: $e')),
          ),
        ),
      ],
    );
  }

  void _showCreateDialog(BuildContext context, WidgetRef ref) {
    final controller = TextEditingController();
    showCupertinoDialog(
      context: context,
      builder: (ctx) => CupertinoAlertDialog(
        title: const Text('New Environment'),
        content: Padding(
          padding: const EdgeInsets.only(top: 12),
          child: CupertinoTextField(
            controller: controller,
            placeholder: 'Environment name',
            autofocus: true,
          ),
        ),
        actions: [
          CupertinoDialogAction(
            isDestructiveAction: true,
            onPressed: () => Navigator.pop(ctx),
            child: const Text('Cancel'),
          ),
          CupertinoDialogAction(
            isDefaultAction: true,
            onPressed: () async {
              final name = controller.text.trim();
              if (name.isEmpty) return;
              Navigator.pop(ctx);
              _openEnvironmentForm(context, ref, name);
            },
            child: const Text('Create'),
          ),
        ],
      ),
    );
  }

  void _openEnvironmentForm(
      BuildContext context, WidgetRef ref, String name) {
    Navigator.of(context, rootNavigator: true).push(
      CupertinoPageRoute(
        builder: (_) => EnvironmentForm(environmentName: name),
      ),
    );
  }
}

class _EnvironmentTile extends ConsumerWidget {
  const _EnvironmentTile({
    required this.name,
    required this.isActive,
  });

  final String name;
  final bool isActive;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return GestureDetector(
      onTap: () async {
        final repo = ref.read(environmentRepositoryProvider);
        await repo.setActiveEnvironment(name);
      },
      child: Container(
        margin: const EdgeInsets.symmetric(vertical: 2),
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
        decoration: BoxDecoration(
          color: isActive
              ? CupertinoColors.activeBlue.withOpacity(0.15)
              : null,
          borderRadius: BorderRadius.circular(6),
        ),
        child: Row(
          children: [
            if (isActive)
              const Padding(
                padding: EdgeInsets.only(right: 8),
                child: Icon(
                  CupertinoIcons.checkmark,
                  size: 14,
                  color: CupertinoColors.activeBlue,
                ),
              ),
            Expanded(
              child: Text(
                name,
                style: TextStyle(
                  fontSize: 14,
                  fontWeight: isActive ? FontWeight.w600 : FontWeight.normal,
                ),
              ),
            ),
            CupertinoButton(
              padding: EdgeInsets.zero,
              minSize: 24,
              onPressed: () {
                Navigator.of(context, rootNavigator: true).push(
                  CupertinoPageRoute(
                    builder: (_) =>
                        EnvironmentForm(environmentName: name),
                  ),
                );
              },
              child: const Icon(
                CupertinoIcons.pencil,
                size: 16,
                color: CupertinoColors.secondaryLabel,
              ),
            ),
            CupertinoButton(
              padding: EdgeInsets.zero,
              minSize: 24,
              onPressed: () => _confirmDelete(context, ref),
              child: const Icon(
                CupertinoIcons.trash,
                size: 16,
                color: CupertinoColors.destructiveRed,
              ),
            ),
          ],
        ),
      ),
    );
  }

  void _confirmDelete(BuildContext context, WidgetRef ref) {
    showCupertinoDialog(
      context: context,
      builder: (ctx) => CupertinoAlertDialog(
        title: Text('Delete "$name"?'),
        content: const Text('This environment configuration will be removed.'),
        actions: [
          CupertinoDialogAction(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('Cancel'),
          ),
          CupertinoDialogAction(
            isDestructiveAction: true,
            onPressed: () async {
              Navigator.pop(ctx);
              final repo = ref.read(environmentRepositoryProvider);
              await repo.deleteEnvironment(name);
            },
            child: const Text('Delete'),
          ),
        ],
      ),
    );
  }
}
