import 'package:flutter/cupertino.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../models/batch.dart';
import '../../providers/queue_providers.dart';
import '../../theme/theme.dart';

class SidebarBatch extends ConsumerWidget {
  const SidebarBatch({super.key, required this.batch});
  final Batch batch;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final stages = batch.stages;
    final selectedIdx = ref.watch(selectedStageIndexProvider);

    return ListView(
      padding: EdgeInsets.zero,
      children: [
        _BatchHeader(batch: batch),
        const _Divider(),
        for (var i = 0; i < stages.length; i++)
          _StageRow(
            stage: stages[i],
            index: i,
            isSelected: i == selectedIdx,
            batch: batch,
          ),
        const _Divider(),
        const _MachineListHeader(),
        for (final entry in batch.entries) _MachineRow(name: entry.name, assigned: entry.assigned, mac: entry.mac),
      ],
    );
  }
}

class _BatchHeader extends StatelessWidget {
  const _BatchHeader({required this.batch});
  final Batch batch;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            batch.prefix,
            style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w600),
            overflow: TextOverflow.ellipsis,
          ),
          const SizedBox(height: 2),
          Text(
            '${batch.count} machine${batch.count == 1 ? '' : 's'} · '
            '${batch.targetType.label}',
            style: const TextStyle(
              fontSize: 11,
              color: CupertinoColors.secondaryLabel,
            ),
          ),
          Text(
            'Mode: ${batch.provisionMode}',
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

class _StageRow extends ConsumerWidget {
  const _StageRow({
    required this.stage,
    required this.index,
    required this.isSelected,
    required this.batch,
  });
  final BatchStage stage;
  final int index;
  final bool isSelected;
  final Batch batch;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final (icon, iconColor) = _stageIcon(stage, batch);
    final selectedBg = CupertinoColors.systemBlue.withValues(alpha: 0.12);

    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: () =>
          ref.read(selectedStageIndexProvider.notifier).state = index,
      child: Container(
        color: isSelected ? selectedBg : null,
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
        child: Row(
          children: [
            Icon(icon, size: 16, color: iconColor),
            const SizedBox(width: 10),
            Expanded(
              child: Text(
                '${index + 1}. ${stage.label}',
                style: TextStyle(
                  fontSize: 13,
                  fontWeight: isSelected ? FontWeight.w600 : FontWeight.w400,
                ),
              ),
            ),
            _stageTrailing(stage, batch),
          ],
        ),
      ),
    );
  }

  (IconData, Color) _stageIcon(BatchStage stage, Batch batch) {
    final complete = _stageComplete(stage, batch);
    if (complete) {
      return (
        CupertinoIcons.checkmark_circle_fill,
        CupertinoColors.activeGreen,
      );
    }
    return (CupertinoIcons.circle, CupertinoColors.systemGrey3);
  }

  bool _stageComplete(BatchStage stage, Batch batch) {
    return switch (stage) {
      BatchStage.provision => true,
      BatchStage.flash ||
      BatchStage.boot =>
        batch.assignedCount == batch.count,
      BatchStage.verify => false,
    };
  }

  Widget _stageTrailing(BatchStage stage, Batch batch) {
    final text = switch (stage) {
      BatchStage.provision => '${batch.count}/${batch.count}',
      BatchStage.flash ||
      BatchStage.boot =>
        '${batch.assignedCount}/${batch.count}',
      _ => '',
    };
    if (text.isEmpty) return const SizedBox.shrink();
    return Text(
      text,
      style: const TextStyle(
        fontSize: 11,
        color: CupertinoColors.secondaryLabel,
        fontFeatures: [FontFeature.tabularFigures()],
      ),
    );
  }
}

class _MachineListHeader extends StatelessWidget {
  const _MachineListHeader();

  @override
  Widget build(BuildContext context) {
    return const Padding(
      padding: EdgeInsets.fromLTRB(16, 12, 16, 6),
      child: Text(
        'Machines',
        style: TextStyle(
          fontSize: 11,
          fontWeight: FontWeight.w600,
          color: CupertinoColors.tertiaryLabel,
          letterSpacing: 0.5,
        ),
      ),
    );
  }
}

class _MachineRow extends StatelessWidget {
  const _MachineRow({required this.name, required this.assigned, this.mac});
  final String name;
  final bool assigned;
  final String? mac;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
      child: Row(
        children: [
          Icon(
            assigned
                ? CupertinoIcons.checkmark_circle_fill
                : CupertinoIcons.circle,
            size: 14,
            color: assigned
                ? CupertinoColors.activeGreen
                : CupertinoColors.systemGrey3,
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              name,
              style: const TextStyle(fontSize: 12),
              overflow: TextOverflow.ellipsis,
            ),
          ),
          if (mac != null)
            Text(
              mac!,
              style: const TextStyle(
                fontSize: 10,
                color: CupertinoColors.tertiaryLabel,
                fontFamilyFallback: monospaceFontFallback,
              ),
            ),
        ],
      ),
    );
  }
}

class _Divider extends StatelessWidget {
  const _Divider();

  @override
  Widget build(BuildContext context) {
    return Container(
      height: 0.5,
      color: CupertinoColors.separator,
      margin: const EdgeInsets.symmetric(vertical: 4),
    );
  }
}
