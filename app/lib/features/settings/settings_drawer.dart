import 'package:flutter/cupertino.dart' show CupertinoIcons;
import 'package:flutter/material.dart'
    show MaterialPageRoute, MenuAnchor, MenuItemButton;
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:macos_ui/macos_ui.dart';

import '../../providers/environment_providers.dart';
import '../../providers/preferences_providers.dart';
import '../../theme/theme.dart';
import 'environment_form.dart';

/// Shared entry point for creating a new environment. Prompts for a name,
/// then pushes the environment form. Used by the settings drawer's "+"
/// button and by the first-launch empty state.
void showCreateEnvironmentFlow(BuildContext context, WidgetRef ref) {
  showMacosSheet(
    context: context,
    builder: (ctx) => _NewEnvironmentSheet(parent: context),
  );
}

class _NewEnvironmentSheet extends StatefulWidget {
  const _NewEnvironmentSheet({required this.parent});
  final BuildContext parent;

  @override
  State<_NewEnvironmentSheet> createState() => _NewEnvironmentSheetState();
}

class _NewEnvironmentSheetState extends State<_NewEnvironmentSheet> {
  final _controller = TextEditingController();

  @override
  void initState() {
    super.initState();
    _controller.addListener(() => setState(() {}));
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _submit() {
    final name = _controller.text.trim();
    if (name.isEmpty) return;
    Navigator.pop(context);
    _pushEnvironmentForm(widget.parent, name);
  }

  @override
  Widget build(BuildContext context) {
    final valid = _controller.text.trim().isNotEmpty;
    return MacosSheet(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 420),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(24, 24, 24, 20),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              const Text(
                'New Environment',
                style: TextStyle(fontSize: 15, fontWeight: FontWeight.w600),
              ),
              const SizedBox(height: 4),
              const Text(
                'An environment holds credentials and network settings for a batch.',
                style: TextStyle(
                  fontSize: 12,
                  color: MacosColors.secondaryLabelColor,
                  height: 1.4,
                ),
              ),
              const SizedBox(height: 16),
              MacosTextField(
                controller: _controller,
                autofocus: true,
                placeholder: 'Environment name',
                onSubmitted: (_) => _submit(),
              ),
              const SizedBox(height: 20),
              Row(
                mainAxisAlignment: MainAxisAlignment.end,
                children: [
                  PushButton(
                    controlSize: ControlSize.large,
                    secondary: true,
                    onPressed: () => Navigator.pop(context),
                    child: const Text('Cancel'),
                  ),
                  const SizedBox(width: 8),
                  PushButton(
                    controlSize: ControlSize.large,
                    onPressed: valid ? _submit : null,
                    child: const Text('Create'),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}

void _pushEnvironmentForm(BuildContext context, String name) {
  Navigator.of(context, rootNavigator: true).push(
    MaterialPageRoute(
      builder: (_) => EnvironmentForm(environmentName: name),
    ),
  );
}

class SettingsDrawer extends ConsumerWidget {
  const SettingsDrawer({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final dividerColor = MacosTheme.of(context).dividerColor;
    return Container(
      color: MacosTheme.of(context).canvasColor,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Container(
            padding: const EdgeInsets.all(16),
            decoration: BoxDecoration(
              border: Border(
                bottom: BorderSide(color: dividerColor, width: 0.5),
              ),
            ),
            child: const Text(
              'Settings',
              style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
            ),
          ),
          Expanded(child: _EnvironmentSection()),
          Container(height: 0.5, color: dividerColor),
          const _AppearanceSection(),
          Container(height: 0.5, color: dividerColor),
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
              color: MacosColors.secondaryLabelColor,
            ),
          ),
          const SizedBox(height: 8),
          _ThemeModePicker(
            mode: mode,
            onChanged: (value) {
              ref.read(themeModeProvider.notifier).state = value;
            },
          ),
        ],
      ),
    );
  }
}

class _ThemeModePicker extends StatelessWidget {
  const _ThemeModePicker({required this.mode, required this.onChanged});

  final AppThemeMode mode;
  final ValueChanged<AppThemeMode> onChanged;

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        for (final option in AppThemeMode.values)
          Padding(
            padding: const EdgeInsets.only(right: 8),
            child: PushButton(
              controlSize: ControlSize.small,
              secondary: option != mode,
              onPressed: option == mode ? null : () => onChanged(option),
              child: Text(_label(option)),
            ),
          ),
      ],
    );
  }

  String _label(AppThemeMode m) => switch (m) {
        AppThemeMode.system => 'System',
        AppThemeMode.light => 'Light',
        AppThemeMode.dark => 'Dark',
      };
}

class _NetworkSection extends ConsumerWidget {
  const _NetworkSection();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final interfaces = ref.watch(networkInterfacesProvider);
    final defaultIface = ref.watch(defaultNetworkInterfaceProvider);
    final selected = ref.watch(selectedNetworkInterfaceProvider);
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
              color: MacosColors.secondaryLabelColor,
            ),
          ),
          const SizedBox(height: 4),
          const Text(
            'Interface for PXE watcher (sniffs DHCP to assign machine names).',
            style: TextStyle(
              fontSize: 11,
              color: MacosColors.tertiaryLabelColor,
              height: 1.3,
            ),
          ),
          const SizedBox(height: 8),
          interfaces.when(
            data: (list) => _InterfacePicker(
              interfaces: list,
              selected: selected,
              autoDetected: defaultIface.valueOrNull,
              onChanged: (value) {
                ref.read(selectedNetworkInterfaceProvider.notifier).state =
                    value;
              },
            ),
            loading: () => const ProgressCircle(radius: 7),
            error: (e, _) => Text(
              '$e',
              style: const TextStyle(
                fontSize: 11,
                color: MacosColors.systemRedColor,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _InterfacePicker extends StatelessWidget {
  const _InterfacePicker({
    required this.interfaces,
    required this.selected,
    required this.autoDetected,
    required this.onChanged,
  });

  final List<String> interfaces;
  final String? selected;
  final String? autoDetected;
  final ValueChanged<String?> onChanged;

  @override
  Widget build(BuildContext context) {
    final label = selected ??
        (autoDetected != null
            ? 'Auto-detect ($autoDetected)'
            : 'Auto-detect');

    return MenuAnchor(
      alignmentOffset: const Offset(0, 4),
      menuChildren: [
        MenuItemButton(
          leadingIcon: MacosIcon(
            selected == null ? CupertinoIcons.checkmark : null,
            size: 13,
            color: MacosColors.controlAccentColor,
          ),
          onPressed: selected == null ? null : () => onChanged(null),
          child: Text(
            autoDetected != null
                ? 'Auto-detect ($autoDetected)'
                : 'Auto-detect',
            style: const TextStyle(fontSize: 13),
          ),
        ),
        for (final name in interfaces)
          MenuItemButton(
            leadingIcon: MacosIcon(
              name == selected ? CupertinoIcons.checkmark : null,
              size: 13,
              color: MacosColors.controlAccentColor,
            ),
            onPressed: name == selected ? null : () => onChanged(name),
            child: Text(
              name,
              style: const TextStyle(
                fontSize: 13,
                fontFamilyFallback: monospaceFontFallback,
              ),
            ),
          ),
      ],
      builder: (context, controller, _) {
        return GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: interfaces.isEmpty
              ? null
              : () {
                  if (controller.isOpen) {
                    controller.close();
                  } else {
                    controller.open();
                  }
                },
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
            decoration: BoxDecoration(
              color: MacosTheme.of(context)
                  .canvasColor
                  .withValues(alpha: 0.5),
              borderRadius: BorderRadius.circular(6),
              border: Border.all(
                color: MacosTheme.of(context).dividerColor,
                width: 0.5,
              ),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  label,
                  style: TextStyle(
                    fontSize: 12,
                    color: MacosTheme.of(context).typography.body.color,
                  ),
                ),
                const SizedBox(width: 6),
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
                  color: MacosColors.secondaryLabelColor,
                ),
              ),
              const Spacer(),
              MacosIconButton(
                icon: const MacosIcon(CupertinoIcons.plus, size: 16),
                boxConstraints: const BoxConstraints(
                  minHeight: 24,
                  minWidth: 24,
                  maxWidth: 32,
                  maxHeight: 32,
                ),
                onPressed: () => showCreateEnvironmentFlow(context, ref),
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
                        color: MacosColors.tertiaryLabelColor,
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
            loading: () => const Center(child: ProgressCircle()),
            error: (e, _) => Center(child: Text('Error: $e')),
          ),
        ),
      ],
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
              ? MacosColors.controlAccentColor.withValues(alpha: 0.15)
              : null,
          borderRadius: BorderRadius.circular(6),
        ),
        child: Row(
          children: [
            if (isActive)
              const Padding(
                padding: EdgeInsets.only(right: 8),
                child: MacosIcon(
                  CupertinoIcons.checkmark,
                  size: 14,
                  color: MacosColors.controlAccentColor,
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
            MacosIconButton(
              icon: const MacosIcon(
                CupertinoIcons.pencil,
                size: 14,
                color: MacosColors.secondaryLabelColor,
              ),
              boxConstraints: const BoxConstraints(
                minHeight: 24,
                minWidth: 24,
                maxWidth: 32,
                maxHeight: 32,
              ),
              onPressed: () {
                Navigator.of(context, rootNavigator: true).push(
                  MaterialPageRoute(
                    builder: (_) =>
                        EnvironmentForm(environmentName: name),
                  ),
                );
              },
            ),
            MacosIconButton(
              icon: const MacosIcon(
                CupertinoIcons.trash,
                size: 14,
                color: MacosColors.systemRedColor,
              ),
              boxConstraints: const BoxConstraints(
                minHeight: 24,
                minWidth: 24,
                maxWidth: 32,
                maxHeight: 32,
              ),
              onPressed: () => _confirmDelete(context, ref),
            ),
          ],
        ),
      ),
    );
  }

  void _confirmDelete(BuildContext context, WidgetRef ref) {
    showMacosAlertDialog<void>(
      context: context,
      builder: (ctx) => MacosAlertDialog(
        appIcon: const MacosIcon(
          CupertinoIcons.trash,
          size: 56,
          color: MacosColors.systemRedColor,
        ),
        title: Text('Delete "$name"?'),
        message: const Text(
          'This environment configuration will be removed.',
          textAlign: TextAlign.center,
        ),
        primaryButton: PushButton(
          controlSize: ControlSize.large,
          onPressed: () async {
            Navigator.pop(ctx);
            final repo = ref.read(environmentRepositoryProvider);
            await repo.deleteEnvironment(name);
          },
          child: const Text('Delete'),
        ),
        secondaryButton: PushButton(
          controlSize: ControlSize.large,
          secondary: true,
          onPressed: () => Navigator.pop(ctx),
          child: const Text('Cancel'),
        ),
      ),
    );
  }
}
