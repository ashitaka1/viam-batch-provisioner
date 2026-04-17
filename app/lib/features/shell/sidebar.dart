import 'dart:convert';
import 'dart:io';

import 'package:flutter/cupertino.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path/path.dart' as p;

import '../../providers/environment_providers.dart';
import '../../providers/provision_providers.dart';
import '../../providers/queue_providers.dart';
import '../batch/sidebar_batch.dart';

class Sidebar extends ConsumerWidget {
  const Sidebar({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final activeEnv = ref.watch(activeEnvironmentProvider).valueOrNull;
    final batch = ref.watch(currentBatchProvider);
    final hasEnv = activeEnv != null;

    return Container(
      color: CupertinoTheme.of(context).barBackgroundColor,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Expanded(
            child: batch != null
                ? SidebarBatch(batch: batch)
                : _EmptyState(hasEnv: hasEnv),
          ),
          if (batch != null) _BatchActions(ref: ref),
        ],
      ),
    );
  }
}

class _BatchActions extends StatelessWidget {
  const _BatchActions({required this.ref});
  final WidgetRef ref;

  Future<void> _resetBatch(BuildContext context) async {
    final confirmed = await _confirm(
      context,
      title: 'Reset batch?',
      message:
          'Marks every machine as unassigned so the same batch can be re-flashed. Staged credentials are kept.',
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

    // Remove MAC-keyed directories (leftover per-machine state)
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
    final confirmed = await _confirm(
      context,
      title: 'Clear batch?',
      message:
          'Removes the queue and all staged machine credentials. This cannot be undone.',
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
    return showCupertinoDialog<bool>(
      context: context,
      builder: (ctx) => CupertinoAlertDialog(
        title: Text(title),
        content: Text(message),
        actions: [
          CupertinoDialogAction(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Cancel'),
          ),
          CupertinoDialogAction(
            isDestructiveAction: true,
            onPressed: () => Navigator.pop(ctx, true),
            child: Text(destructiveLabel),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: const BoxDecoration(
        border: Border(
          top: BorderSide(color: CupertinoColors.separator, width: 0.5),
        ),
      ),
      child: Row(
        children: [
          Expanded(
            child: CupertinoButton(
              padding: const EdgeInsets.symmetric(vertical: 8),
              color: CupertinoColors.systemGrey5,
              borderRadius: BorderRadius.circular(8),
              onPressed: () => _resetBatch(context),
              child: const Text(
                'Reset',
                style: TextStyle(
                  fontSize: 13,
                  color: CupertinoColors.label,
                ),
              ),
            ),
          ),
          const SizedBox(width: 8),
          Expanded(
            child: CupertinoButton(
              padding: const EdgeInsets.symmetric(vertical: 8),
              color: CupertinoColors.destructiveRed,
              borderRadius: BorderRadius.circular(8),
              onPressed: () => _clearBatch(context),
              child: const Text(
                'Clear',
                style: TextStyle(
                  fontSize: 13,
                  color: CupertinoColors.white,
                ),
              ),
            ),
          ),
        ],
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
                color: CupertinoColors.secondaryLabel,
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
                color: CupertinoColors.tertiaryLabel,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
