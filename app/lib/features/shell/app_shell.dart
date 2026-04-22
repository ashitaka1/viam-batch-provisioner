import 'package:flutter/cupertino.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:macos_ui/macos_ui.dart';

import '../../models/batch.dart';
import '../../providers/environment_providers.dart';
import '../../providers/queue_providers.dart';
import '../batch/new_batch_form.dart';
import '../batch/provision_stage_panel.dart';
import '../boot/boot_stage_panel.dart';
import '../flash/flash_stage_panel.dart';
import '../settings/settings_drawer.dart' show SettingsDrawer, showCreateEnvironmentFlow;
import '../verify/verify_stage_panel.dart';
import 'toolbar.dart';
import 'sidebar.dart';

final settingsOpenProvider = StateProvider<bool>((ref) => false);

class AppShell extends ConsumerWidget {
  const AppShell({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final settingsOpen = ref.watch(settingsOpenProvider);
    final dividerColor = MacosTheme.of(context).dividerColor;

    return MacosWindow(
      child: MacosScaffold(
        toolBar: buildAppToolBar(context, ref),
        children: [
          ContentArea(
            builder: (context, _) {
              return Row(
                children: [
                  SizedBox(
                    width: 240,
                    child: ColoredBox(
                      color: MacosTheme.of(context).canvasColor,
                      child: const BatchSidebar(),
                    ),
                  ),
                  Container(width: 1, color: dividerColor),
                  const Expanded(child: _MainPanel()),
                  if (settingsOpen) ...[
                    Container(width: 1, color: dividerColor),
                    const SizedBox(width: 320, child: SettingsDrawer()),
                  ],
                ],
              );
            },
          ),
        ],
      ),
    );
  }
}

class _MainPanel extends ConsumerWidget {
  const _MainPanel();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final activeEnv = ref.watch(activeEnvironmentProvider);
    final batch = ref.watch(currentBatchProvider);
    final selectedStage = ref.watch(selectedStageProvider);

    return activeEnv.when(
      data: (env) {
        if (env == null) return const _NoEnvironment();
        if (batch == null) return const NewBatchForm();
        return switch (selectedStage) {
          BatchStage.provision => const ProvisionStagePanel(),
          BatchStage.flash => const FlashStagePanel(),
          BatchStage.boot => const BootStagePanel(),
          BatchStage.verify => const VerifyStagePanel(),
          null => const ProvisionStagePanel(),
        };
      },
      loading: () => const Center(child: ProgressCircle()),
      error: (e, _) => Center(child: Text('Error: $e')),
    );
  }
}

class _NoEnvironment extends ConsumerWidget {
  const _NoEnvironment();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const MacosIcon(
              CupertinoIcons.cube_box,
              size: 40,
              color: MacosColors.tertiaryLabelColor,
            ),
            const SizedBox(height: 16),
            const Text(
              'No environment yet',
              style: TextStyle(
                fontSize: 17,
                fontWeight: FontWeight.w600,
              ),
            ),
            const SizedBox(height: 6),
            const Text(
              'Environments hold the credentials and network settings '
              'for a batch. Create one to begin provisioning.',
              textAlign: TextAlign.center,
              style: TextStyle(
                fontSize: 12,
                color: MacosColors.secondaryLabelColor,
                height: 1.4,
              ),
            ),
            const SizedBox(height: 20),
            PushButton(
              controlSize: ControlSize.large,
              onPressed: () => showCreateEnvironmentFlow(context, ref),
              child: const Text('Create environment'),
            ),
          ],
        ),
      ),
    );
  }
}
