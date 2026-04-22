import 'package:flutter/cupertino.dart' show CupertinoIcons;
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:macos_ui/macos_ui.dart';

import '../../models/batch.dart';
import '../../models/queue_entry.dart';
import '../../providers/queue_providers.dart';
import '../../theme/theme.dart';

class VerifyStagePanel extends ConsumerWidget {
  const VerifyStagePanel({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final batch = ref.watch(currentBatchProvider);
    if (batch == null) return const SizedBox.shrink();

    final done = batch.assignedCount;
    final total = batch.count;
    final pending = total - done;

    return Padding(
      padding: const EdgeInsets.all(24),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _Header(done: done, total: total, pending: pending, batch: batch),
          const SizedBox(height: 20),
          Expanded(child: _MachineTable(batch: batch)),
        ],
      ),
    );
  }
}

class _Header extends StatelessWidget {
  const _Header({
    required this.done,
    required this.total,
    required this.pending,
    required this.batch,
  });
  final int done;
  final int total;
  final int pending;
  final Batch batch;

  @override
  Widget build(BuildContext context) {
    final allDone = pending == 0;
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.only(right: 10, top: 2),
          child: MacosIcon(
            allDone
                ? CupertinoIcons.checkmark_seal_fill
                : CupertinoIcons.clock,
            size: 22,
            color: allDone
                ? MacosColors.systemGreenColor
                : MacosColors.systemOrangeColor,
          ),
        ),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                allDone
                    ? 'All machines provisioned'
                    : '$done of $total provisioned',
                style: const TextStyle(
                  fontSize: 20,
                  fontWeight: FontWeight.w600,
                ),
              ),
              const SizedBox(height: 2),
              Text(
                allDone
                    ? 'Power on each ${batch.targetType.label} and wait for first-boot setup to complete.'
                    : '$pending pending. Complete the ${_stageBefore(batch).label} stage to finish.',
                style: const TextStyle(
                  fontSize: 13,
                  color: MacosColors.secondaryLabelColor,
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }

  BatchStage _stageBefore(Batch batch) {
    final stages = batch.stages;
    final verifyIdx = stages.indexOf(BatchStage.verify);
    return verifyIdx > 0 ? stages[verifyIdx - 1] : BatchStage.provision;
  }
}

class _MachineTable extends StatelessWidget {
  const _MachineTable({required this.batch});
  final Batch batch;

  @override
  Widget build(BuildContext context) {
    final bg = MacosTheme.of(context).canvasColor;
    final divider = MacosTheme.of(context).dividerColor;
    return Container(
      decoration: BoxDecoration(
        color: bg,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: divider, width: 0.5),
      ),
      child: Column(
        children: [
          const _TableHeader(),
          Container(height: 0.5, color: divider),
          Expanded(
            child: ListView.separated(
              itemCount: batch.entries.length,
              separatorBuilder: (_, __) => Container(
                height: 0.5,
                color: divider,
              ),
              itemBuilder: (context, i) => _MachineRow(
                entry: batch.entries[i],
                targetType: batch.targetType,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _TableHeader extends StatelessWidget {
  const _TableHeader();

  @override
  Widget build(BuildContext context) {
    return const Padding(
      padding: EdgeInsets.symmetric(horizontal: 16, vertical: 10),
      child: Row(
        children: [
          SizedBox(width: 24),
          Expanded(flex: 3, child: _Th('Machine')),
          Expanded(flex: 3, child: _Th('MAC / Slot')),
          Expanded(flex: 2, child: _Th('Status')),
        ],
      ),
    );
  }
}

class _Th extends StatelessWidget {
  const _Th(this.label);
  final String label;

  @override
  Widget build(BuildContext context) {
    return Text(
      label,
      style: const TextStyle(
        fontSize: 11,
        fontWeight: FontWeight.w600,
        color: MacosColors.tertiaryLabelColor,
        letterSpacing: 0.5,
      ),
    );
  }
}

class _MachineRow extends StatelessWidget {
  const _MachineRow({required this.entry, required this.targetType});
  final QueueEntry entry;
  final BatchTargetType targetType;

  @override
  Widget build(BuildContext context) {
    final assigned = entry.assigned;
    final identifier = entry.mac ?? entry.slotId ?? '—';
    final statusLabel = _statusLabel(assigned, targetType);
    final statusColor = assigned
        ? MacosColors.systemGreenColor
        : MacosColors.secondaryLabelColor;

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
      child: Row(
        children: [
          SizedBox(
            width: 24,
            child: MacosIcon(
              assigned
                  ? CupertinoIcons.checkmark_circle_fill
                  : CupertinoIcons.circle,
              size: 16,
              color: assigned
                  ? MacosColors.systemGreenColor
                  : MacosColors.systemGrayColor,
            ),
          ),
          Expanded(
            flex: 3,
            child: Text(
              entry.name,
              style: const TextStyle(fontSize: 13),
              overflow: TextOverflow.ellipsis,
            ),
          ),
          Expanded(
            flex: 3,
            child: Text(
              identifier,
              style: const TextStyle(
                fontSize: 12,
                fontFamilyFallback: monospaceFontFallback,
                color: MacosColors.secondaryLabelColor,
              ),
              overflow: TextOverflow.ellipsis,
            ),
          ),
          Expanded(
            flex: 2,
            child: Text(
              statusLabel,
              style: TextStyle(fontSize: 12, color: statusColor),
            ),
          ),
        ],
      ),
    );
  }

  String _statusLabel(bool assigned, BatchTargetType t) {
    if (!assigned) {
      return switch (t) {
        BatchTargetType.pi => 'waiting for flash',
        BatchTargetType.x86 => 'waiting for PXE',
      };
    }
    return switch (t) {
      BatchTargetType.pi => 'flashed',
      BatchTargetType.x86 => 'PXE assigned',
    };
  }
}
