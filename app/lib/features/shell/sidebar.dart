import 'dart:convert';
import 'dart:io';

import 'package:flutter/cupertino.dart' show CupertinoIcons;
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:macos_ui/macos_ui.dart';
import 'package:path/path.dart' as p;

import '../../providers/environment_providers.dart';
import '../../providers/provision_providers.dart';
import '../../providers/queue_providers.dart';
import '../../theme/theme.dart';
import '../batch/sidebar_batch.dart';

class BatchSidebar extends ConsumerWidget {
  const BatchSidebar({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final activeEnv = ref.watch(activeEnvironmentProvider).valueOrNull;
    final batch = ref.watch(currentBatchProvider);
    final hasEnv = activeEnv != null;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Expanded(
          child: batch != null
              ? SidebarBatch(batch: batch)
              : _EmptyState(hasEnv: hasEnv),
        ),
        if (batch != null)
          _BatchActions(ref: ref, batchPrefix: batch.prefix),
      ],
    );
  }
}

class _BatchActions extends StatelessWidget {
  const _BatchActions({required this.ref, required this.batchPrefix});
  final WidgetRef ref;
  final String batchPrefix;

  Future<void> _resetBatch(BuildContext context) async {
    final confirmed = await _confirm(
      context,
      title: 'Reset batch?',
      message:
          'Marks every machine as unassigned and clears MAC bindings so the batch can be re-flashed or re-PXE-booted. Credentials staged in slot directories are kept.',
      destructiveLabel: 'Reset',
    );
    if (confirmed != true) return;

    final repo = ref.read(queueRepositoryProvider);
    final entries = await repo.loadQueue();
    final reset = [
      for (final e in entries)
        {
          'name': e.name,
          'assigned': false,
          if (e.slotId != null) 'slot_id': e.slotId,
        },
    ];
    final path = p.join(repo.machinesDir, 'queue.json');
    await File(path).writeAsString(const JsonEncoder.withIndent('  ')
        .convert(reset));

    final dir = Directory(repo.machinesDir);
    if (await dir.exists()) {
      await for (final entry in dir.list()) {
        final name = p.basename(entry.path);
        if (RegExp(r'^[0-9a-f]{2}:').hasMatch(name)) {
          await entry.delete(recursive: true);
        }
      }
    }
  }

  Future<void> _clearBatch(BuildContext context) async {
    final confirmed = await _confirmTypeToProceed(
      context,
      title: 'Clear batch?',
      message:
          'Removes the queue and all staged machine credentials. This cannot be undone.\nType the batch name to confirm.',
      expectedText: batchPrefix,
      destructiveLabel: 'Clear',
    );
    if (confirmed != true) return;

    final repo = ref.read(queueRepositoryProvider);
    final dir = Directory(repo.machinesDir);
    if (await dir.exists()) {
      await for (final entry in dir.list()) {
        final name = p.basename(entry.path);
        if (name == 'queue.json' ||
            name == 'batch.json' ||
            name.startsWith('slot-') ||
            RegExp(r'^[0-9a-f]{2}:').hasMatch(name)) {
          await entry.delete(recursive: true);
        }
      }
    }
    ref.read(provisionControllerProvider.notifier).reset();
  }

  Future<bool?> _confirm(
    BuildContext context, {
    required String title,
    required String message,
    required String destructiveLabel,
  }) {
    return showMacosAlertDialog<bool>(
      context: context,
      builder: (ctx) => MacosAlertDialog(
        appIcon: const MacosIcon(
          CupertinoIcons.exclamationmark_triangle_fill,
          size: 56,
          color: MacosColors.systemYellowColor,
        ),
        title: Text(title),
        message: Text(
          message,
          textAlign: TextAlign.center,
        ),
        primaryButton: PushButton(
          controlSize: ControlSize.large,
          onPressed: () => Navigator.pop(ctx, true),
          child: Text(destructiveLabel),
        ),
        secondaryButton: PushButton(
          controlSize: ControlSize.large,
          secondary: true,
          onPressed: () => Navigator.pop(ctx, false),
          child: const Text('Cancel'),
        ),
      ),
    );
  }

  Future<bool?> _confirmTypeToProceed(
    BuildContext context, {
    required String title,
    required String message,
    required String expectedText,
    required String destructiveLabel,
  }) {
    return showMacosSheet<bool>(
      context: context,
      builder: (ctx) => _TypeToConfirmSheet(
        title: title,
        message: message,
        expectedText: expectedText,
        destructiveLabel: destructiveLabel,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final dividerColor = MacosTheme.of(context).dividerColor;
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        border: Border(top: BorderSide(color: dividerColor, width: 0.5)),
      ),
      child: Row(
        children: [
          Expanded(
            child: PushButton(
              controlSize: ControlSize.large,
              secondary: true,
              onPressed: () => _resetBatch(context),
              child: const Text('Reset'),
            ),
          ),
          const SizedBox(width: 8),
          Expanded(
            child: DestructivePushButton(
              onPressed: () => _clearBatch(context),
              child: const Text('Clear'),
            ),
          ),
        ],
      ),
    );
  }
}

class _TypeToConfirmSheet extends StatefulWidget {
  const _TypeToConfirmSheet({
    required this.title,
    required this.message,
    required this.expectedText,
    required this.destructiveLabel,
  });
  final String title;
  final String message;
  final String expectedText;
  final String destructiveLabel;

  @override
  State<_TypeToConfirmSheet> createState() => _TypeToConfirmSheetState();
}

class _TypeToConfirmSheetState extends State<_TypeToConfirmSheet> {
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

  @override
  Widget build(BuildContext context) {
    final matches = _controller.text.trim() == widget.expectedText;
    return MacosSheet(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 420),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(24, 24, 24, 20),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const MacosIcon(
                    CupertinoIcons.exclamationmark_triangle_fill,
                    size: 36,
                    color: MacosColors.systemYellowColor,
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Text(
                          widget.title,
                          style: const TextStyle(
                            fontSize: 15,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                        const SizedBox(height: 4),
                        Text(
                          widget.message,
                          style: const TextStyle(
                            fontSize: 12,
                            color: MacosColors.secondaryLabelColor,
                            height: 1.4,
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 16),
              MacosTextField(
                controller: _controller,
                autofocus: true,
                placeholder: widget.expectedText,
                autocorrect: false,
                enableSuggestions: false,
                onSubmitted: (_) {
                  if (matches) Navigator.pop(context, true);
                },
              ),
              const SizedBox(height: 20),
              Row(
                mainAxisAlignment: MainAxisAlignment.end,
                children: [
                  PushButton(
                    controlSize: ControlSize.large,
                    secondary: true,
                    onPressed: () => Navigator.pop(context, false),
                    child: const Text('Cancel'),
                  ),
                  const SizedBox(width: 8),
                  DestructivePushButton(
                    onPressed: matches
                        ? () => Navigator.pop(context, true)
                        : null,
                    child: Text(widget.destructiveLabel),
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

class _EmptyState extends StatelessWidget {
  const _EmptyState({required this.hasEnv});
  final bool hasEnv;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Text(
              'No batch',
              style: TextStyle(
                fontSize: 13,
                fontWeight: FontWeight.w600,
                color: MacosColors.secondaryLabelColor,
              ),
            ),
            const SizedBox(height: 6),
            Text(
              hasEnv
                  ? 'Create a new batch to begin provisioning.'
                  : 'Select an environment first.',
              textAlign: TextAlign.center,
              style: const TextStyle(
                fontSize: 11,
                color: MacosColors.tertiaryLabelColor,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
