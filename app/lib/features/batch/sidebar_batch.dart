import 'package:flutter/cupertino.dart' show CupertinoIcons;
import 'package:flutter/material.dart' show Tooltip;
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:macos_ui/macos_ui.dart';

import '../../models/batch.dart';
import '../../providers/provision_providers.dart';
import '../../providers/queue_providers.dart';
import '../../theme/theme.dart';

class SidebarBatch extends ConsumerWidget {
  const SidebarBatch({super.key, required this.batch});
  final Batch batch;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final stages = batch.stages;
    final selectedIdx = ref.watch(selectedStageIndexProvider);
    final provisionRunning = ref.watch(
      provisionControllerProvider.select((s) => s.isRunning),
    );

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
            provisionRunning: provisionRunning,
          ),
        const _Divider(),
        const _MachineListHeader(),
        for (final entry in batch.entries)
          _MachineRow(
            name: entry.name,
            assigned: entry.assigned,
            mac: entry.mac,
          ),
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
              color: MacosColors.secondaryLabelColor,
            ),
          ),
          Text(
            'Mode: ${batch.provisionMode}',
            style: const TextStyle(
              fontSize: 11,
              color: MacosColors.secondaryLabelColor,
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
    required this.provisionRunning,
  });
  final BatchStage stage;
  final int index;
  final bool isSelected;
  final Batch batch;
  final bool provisionRunning;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final (icon, iconColor) = _stageIcon(stage, batch, provisionRunning);
    final enabled = _stageEnabled(stage, batch, provisionRunning);
    final textColor = MacosTheme.of(context).typography.body.color;
    final selectedBg =
        MacosColors.controlAccentColor.withValues(alpha: 0.12);

    final row = Container(
      color: isSelected ? selectedBg : null,
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      child: Row(
        children: [
          MacosIcon(icon, size: 16, color: iconColor),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              '${index + 1}. ${stage.label}',
              style: TextStyle(
                fontSize: 13,
                fontWeight: isSelected ? FontWeight.w600 : FontWeight.w400,
                color: enabled
                    ? textColor
                    : MacosColors.tertiaryLabelColor,
              ),
            ),
          ),
          _stageTrailing(stage, batch),
        ],
      ),
    );

    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: enabled
          ? () =>
              ref.read(selectedStageIndexProvider.notifier).state = index
          : null,
      child: Tooltip(
        message:
            enabled ? '' : _disabledReason(stage, batch, provisionRunning),
        waitDuration: const Duration(milliseconds: 400),
        child: row,
      ),
    );
  }

  (IconData, Color) _stageIcon(
      BatchStage stage, Batch batch, bool provisionRunning) {
    if (_stageComplete(stage, batch, provisionRunning)) {
      return (
        CupertinoIcons.checkmark_circle_fill,
        MacosColors.systemGreenColor,
      );
    }
    return (CupertinoIcons.circle, MacosColors.systemGrayColor);
  }

  bool _stageComplete(BatchStage stage, Batch batch, bool provisionRunning) {
    final allAssigned = batch.count > 0 && batch.assignedCount == batch.count;
    return switch (stage) {
      BatchStage.provision => batch.count > 0 && !provisionRunning,
      BatchStage.flash || BatchStage.boot => allAssigned,
      BatchStage.verify => allAssigned,
    };
  }

  bool _stageEnabled(BatchStage stage, Batch batch, bool provisionRunning) {
    final provisionDone = batch.count > 0 && !provisionRunning;
    final allAssigned = batch.count > 0 && batch.assignedCount == batch.count;
    return switch (stage) {
      BatchStage.provision => true,
      BatchStage.flash || BatchStage.boot => provisionDone,
      BatchStage.verify => allAssigned,
    };
  }

  String _disabledReason(
      BatchStage stage, Batch batch, bool provisionRunning) {
    return switch (stage) {
      BatchStage.provision => '',
      BatchStage.flash || BatchStage.boot => provisionRunning
          ? 'Provisioning is still running'
          : 'Complete Provision first',
      BatchStage.verify => 'No machines have been flashed yet',
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
        color: MacosColors.secondaryLabelColor,
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
          color: MacosColors.tertiaryLabelColor,
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
          MacosIcon(
            assigned
                ? CupertinoIcons.checkmark_circle_fill
                : CupertinoIcons.circle,
            size: 14,
            color: assigned
                ? MacosColors.systemGreenColor
                : MacosColors.systemGrayColor,
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
                color: MacosColors.tertiaryLabelColor,
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
      color: MacosTheme.of(context).dividerColor,
      margin: const EdgeInsets.symmetric(vertical: 4),
    );
  }
}
