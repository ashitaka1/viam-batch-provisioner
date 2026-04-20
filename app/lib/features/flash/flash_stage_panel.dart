import 'package:flutter/cupertino.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/disk_utils.dart';
import '../../models/flash_state.dart';
import '../../providers/flash_providers.dart';
import '../../providers/queue_providers.dart';
import '../../theme/theme.dart';

class FlashStagePanel extends ConsumerWidget {
  const FlashStagePanel({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final batch = ref.watch(currentBatchProvider);
    final flash = ref.watch(flashControllerProvider);
    final controller = ref.read(flashControllerProvider.notifier);

    if (batch == null) return const SizedBox.shrink();

    final unflashed = batch.entries.where((e) => !e.assigned).toList();
    final remaining = unflashed.length;
    final done = batch.count - remaining;

    return Padding(
      padding: const EdgeInsets.all(24),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _Header(done: done, total: batch.count),
          const SizedBox(height: 20),
          Expanded(
            child: AnimatedSwitcher(
              duration: const Duration(milliseconds: 200),
              switchInCurve: Curves.easeOutCubic,
              switchOutCurve: Curves.easeInCubic,
              child: KeyedSubtree(
                key: ValueKey(flash.phase),
                child: switch (flash.phase) {
                  FlashPhase.idle => _PickMachine(
                      unflashed: unflashed.map((e) => e.name).toList(),
                      onPick: controller.begin,
                    ),
                  FlashPhase.awaitInsert => _AwaitInsert(
                      name: flash.machineName!,
                      onRescan: controller.rescan,
                      onCancel: controller.cancel,
                    ),
                  FlashPhase.choose => _Choose(
                      candidates: flash.candidateDisks,
                      machineName: flash.machineName!,
                      onPick: controller.pickCandidate,
                      onRescan: controller.rescan,
                      onCancel: controller.cancel,
                    ),
                  FlashPhase.detected => _Detected(
                      state: flash,
                      onConfirm: controller.flash,
                      onRescan: controller.rescan,
                      onCancel: controller.cancel,
                    ),
                  FlashPhase.flashing => _Flashing(
                      state: flash,
                      onCancel: () => _confirmCancelFlash(context, controller),
                    ),
                  FlashPhase.done => _Done(
                      name: flash.machineName!,
                      remaining: remaining,
                      onNext: controller.finish,
                    ),
                  FlashPhase.error => _Error(
                      message: flash.error ?? 'Unknown error',
                      onRetry: () => controller.begin(flash.machineName!),
                      onCancel: controller.cancel,
                    ),
                },
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _Header extends StatelessWidget {
  const _Header({required this.done, required this.total});
  final int done;
  final int total;

  @override
  Widget build(BuildContext context) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.center,
      children: [
        const Icon(
          CupertinoIcons.square_stack_3d_down_right,
          size: 22,
          color: CupertinoColors.systemBlue,
        ),
        const SizedBox(width: 10),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text(
                'Flash SD cards',
                style: TextStyle(fontSize: 20, fontWeight: FontWeight.w600),
              ),
              const SizedBox(height: 2),
              Text(
                '$done of $total flashed.',
                style: const TextStyle(
                  fontSize: 13,
                  color: CupertinoColors.secondaryLabel,
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }
}

class _PickMachine extends StatelessWidget {
  const _PickMachine({required this.unflashed, required this.onPick});
  final List<String> unflashed;
  final void Function(String) onPick;

  @override
  Widget build(BuildContext context) {
    if (unflashed.isEmpty) {
      return const Center(
        child: Text(
          'All machines have been flashed.',
          style: TextStyle(fontSize: 14, color: CupertinoColors.secondaryLabel),
        ),
      );
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Text(
          'Choose the next machine to flash.',
          style: TextStyle(fontSize: 13, color: CupertinoColors.secondaryLabel),
        ),
        const SizedBox(height: 12),
        Expanded(
          child: Container(
            decoration: BoxDecoration(
              color: CupertinoColors.systemGrey6.resolveFrom(context),
              borderRadius: BorderRadius.circular(8),
            ),
            child: ListView.separated(
              padding: const EdgeInsets.symmetric(vertical: 4),
              itemCount: unflashed.length,
              separatorBuilder: (_, __) => Container(
                height: 0.5,
                color: CupertinoColors.separator,
                margin: const EdgeInsets.symmetric(horizontal: 12),
              ),
              itemBuilder: (context, i) {
                final name = unflashed[i];
                return CupertinoButton(
                  padding: const EdgeInsets.symmetric(
                      horizontal: 16, vertical: 10),
                  onPressed: () => onPick(name),
                  child: Row(
                    children: [
                      Expanded(
                        child: Text(
                          name,
                          style: const TextStyle(
                            fontSize: 13,
                            color: CupertinoColors.label,
                          ),
                        ),
                      ),
                      const Icon(
                        CupertinoIcons.chevron_right,
                        size: 14,
                        color: CupertinoColors.tertiaryLabel,
                      ),
                    ],
                  ),
                );
              },
            ),
          ),
        ),
      ],
    );
  }
}

class _AwaitInsert extends StatelessWidget {
  const _AwaitInsert({
    required this.name,
    required this.onRescan,
    required this.onCancel,
  });
  final String name;
  final VoidCallback onRescan;
  final VoidCallback onCancel;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Icon(
            CupertinoIcons.arrow_down_square,
            size: 40,
            color: CupertinoColors.systemBlue,
          ),
          const SizedBox(height: 12),
          Text(
            'Insert SD card for "$name"',
            style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w600),
          ),
          const SizedBox(height: 6),
          const Text(
            'Detecting new external disks…',
            style: TextStyle(
              fontSize: 12,
              color: CupertinoColors.secondaryLabel,
            ),
          ),
          const SizedBox(height: 16),
          const CupertinoActivityIndicator(radius: 10),
          const SizedBox(height: 20),
          Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              CupertinoButton(
                onPressed: onRescan,
                child: const Text('Rescan'),
              ),
              const SizedBox(width: 8),
              CupertinoButton(
                onPressed: onCancel,
                child: const Text('Cancel'),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class _Detected extends StatelessWidget {
  const _Detected({
    required this.state,
    required this.onConfirm,
    required this.onRescan,
    required this.onCancel,
  });
  final FlashState state;
  final VoidCallback onConfirm;
  final VoidCallback onRescan;
  final VoidCallback onCancel;

  @override
  Widget build(BuildContext context) {
    final disk = state.detectedDisk!;
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Icon(
            CupertinoIcons.exclamationmark_triangle_fill,
            size: 40,
            color: CupertinoColors.systemOrange,
          ),
          const SizedBox(height: 12),
          Text(
            'Erase and flash ${disk.device}?',
            style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w600),
          ),
          const SizedBox(height: 8),
          Text(
            '${disk.description}  ·  ${disk.sizeHuman}',
            style: const TextStyle(
              fontSize: 12,
              color: CupertinoColors.secondaryLabel,
            ),
          ),
          const SizedBox(height: 8),
          const Text(
            'All data on this disk will be erased.',
            style: TextStyle(fontSize: 12, color: CupertinoColors.systemRed),
          ),
          const SizedBox(height: 20),
          Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              CupertinoButton.filled(
                onPressed: onConfirm,
                child: Text('Flash "${state.machineName}"'),
              ),
              const SizedBox(width: 8),
              CupertinoButton(
                onPressed: onRescan,
                child: const Text('Rescan'),
              ),
              const SizedBox(width: 8),
              CupertinoButton(
                onPressed: onCancel,
                child: const Text('Cancel'),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class _Flashing extends StatelessWidget {
  const _Flashing({required this.state, required this.onCancel});
  final FlashState state;
  final VoidCallback onCancel;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          children: [
            const CupertinoActivityIndicator(radius: 10),
            const SizedBox(width: 10),
            Expanded(
              child: Text(
                'Flashing ${state.detectedDisk?.device ?? ''} as "${state.machineName}"',
                style: const TextStyle(
                  fontSize: 14,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
            CupertinoButton(
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
              onPressed: onCancel,
              child: const Text(
                'Cancel',
                style: TextStyle(
                  fontSize: 13,
                  color: CupertinoColors.systemRed,
                ),
              ),
            ),
          ],
        ),
        const SizedBox(height: 12),
        Expanded(child: _LogView(lines: state.progressLines)),
      ],
    );
  }
}

class _Choose extends StatelessWidget {
  const _Choose({
    required this.candidates,
    required this.machineName,
    required this.onPick,
    required this.onRescan,
    required this.onCancel,
  });

  final List<DiskInfo> candidates;
  final String machineName;
  final void Function(DiskInfo) onPick;
  final VoidCallback onRescan;
  final VoidCallback onCancel;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          children: [
            const Icon(
              CupertinoIcons.exclamationmark_triangle_fill,
              size: 22,
              color: CupertinoColors.systemOrange,
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Text(
                'Multiple new disks detected — pick the SD card for "$machineName".',
                style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w600),
              ),
            ),
          ],
        ),
        const SizedBox(height: 6),
        const Text(
          'Eject anything that isn\'t the target card, then click Rescan, or pick the right device below.',
          style: TextStyle(fontSize: 12, color: CupertinoColors.secondaryLabel),
        ),
        const SizedBox(height: 14),
        Expanded(
          child: Container(
            decoration: BoxDecoration(
              color: CupertinoColors.systemGrey6.resolveFrom(context),
              borderRadius: BorderRadius.circular(8),
            ),
            child: ListView.separated(
              padding: const EdgeInsets.symmetric(vertical: 4),
              itemCount: candidates.length,
              separatorBuilder: (_, __) => Container(
                height: 0.5,
                color: CupertinoColors.separator,
                margin: const EdgeInsets.symmetric(horizontal: 12),
              ),
              itemBuilder: (context, i) {
                final d = candidates[i];
                return CupertinoButton(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
                  onPressed: () => onPick(d),
                  child: Row(
                    children: [
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              d.device,
                              style: const TextStyle(
                                fontSize: 13,
                                fontFamilyFallback: monospaceFontFallback,
                                color: CupertinoColors.label,
                              ),
                            ),
                            const SizedBox(height: 2),
                            Text(
                              '${d.description}  ·  ${d.sizeHuman}',
                              style: const TextStyle(
                                fontSize: 11,
                                color: CupertinoColors.secondaryLabel,
                              ),
                            ),
                          ],
                        ),
                      ),
                      const Icon(
                        CupertinoIcons.chevron_right,
                        size: 14,
                        color: CupertinoColors.tertiaryLabel,
                      ),
                    ],
                  ),
                );
              },
            ),
          ),
        ),
        const SizedBox(height: 12),
        Row(
          mainAxisAlignment: MainAxisAlignment.end,
          children: [
            CupertinoButton(onPressed: onRescan, child: const Text('Rescan')),
            const SizedBox(width: 8),
            CupertinoButton(onPressed: onCancel, child: const Text('Cancel')),
          ],
        ),
      ],
    );
  }
}

Future<void> _confirmCancelFlash(
  BuildContext context,
  FlashController controller,
) async {
  final confirmed = await showCupertinoDialog<bool>(
    context: context,
    builder: (ctx) => CupertinoAlertDialog(
      title: const Text('Cancel flash?'),
      content: const Text(
        'Stopping mid-write leaves the SD card in an inconsistent state. '
        'You\'ll need to re-flash it before the Pi will boot.',
      ),
      actions: [
        CupertinoDialogAction(
          onPressed: () => Navigator.pop(ctx, false),
          child: const Text('Keep flashing'),
        ),
        CupertinoDialogAction(
          isDestructiveAction: true,
          onPressed: () => Navigator.pop(ctx, true),
          child: const Text('Cancel flash'),
        ),
      ],
    ),
  );
  if (confirmed == true) {
    await controller.cancel();
  }
}

class _Done extends StatelessWidget {
  const _Done({
    required this.name,
    required this.remaining,
    required this.onNext,
  });
  final String name;
  final int remaining;
  final VoidCallback onNext;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Icon(
            CupertinoIcons.checkmark_circle_fill,
            size: 40,
            color: CupertinoColors.activeGreen,
          ),
          const SizedBox(height: 12),
          Text(
            'Done: $name',
            style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w600),
          ),
          const SizedBox(height: 6),
          Text(
            remaining == 0
                ? 'All SD cards flashed. You can now insert them into the Pis.'
                : 'Label this card and remove it. $remaining machine${remaining == 1 ? '' : 's'} left.',
            textAlign: TextAlign.center,
            style: const TextStyle(
              fontSize: 12,
              color: CupertinoColors.secondaryLabel,
            ),
          ),
          const SizedBox(height: 20),
          CupertinoButton.filled(
            onPressed: onNext,
            child: Text(remaining == 0 ? 'Finish' : 'Next machine'),
          ),
        ],
      ),
    );
  }
}

class _Error extends StatelessWidget {
  const _Error({
    required this.message,
    required this.onRetry,
    required this.onCancel,
  });
  final String message;
  final VoidCallback onRetry;
  final VoidCallback onCancel;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Icon(
            CupertinoIcons.xmark_octagon_fill,
            size: 40,
            color: CupertinoColors.systemRed,
          ),
          const SizedBox(height: 12),
          const Text(
            'Flash failed',
            style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600),
          ),
          const SizedBox(height: 6),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 32),
            child: Text(
              message,
              textAlign: TextAlign.center,
              style: const TextStyle(
                fontSize: 12,
                color: CupertinoColors.secondaryLabel,
              ),
            ),
          ),
          const SizedBox(height: 20),
          Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              CupertinoButton.filled(
                onPressed: onRetry,
                child: const Text('Try again'),
              ),
              const SizedBox(width: 8),
              CupertinoButton(
                onPressed: onCancel,
                child: const Text('Cancel'),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class _LogView extends StatefulWidget {
  const _LogView({required this.lines});
  final List<String> lines;

  @override
  State<_LogView> createState() => _LogViewState();
}

class _LogViewState extends State<_LogView> {
  final _scroll = ScrollController();

  @override
  void didUpdateWidget(covariant _LogView old) {
    super.didUpdateWidget(old);
    if (widget.lines.length != old.lines.length) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (_scroll.hasClients) {
          _scroll.jumpTo(_scroll.position.maxScrollExtent);
        }
      });
    }
  }

  @override
  void dispose() {
    _scroll.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (widget.lines.isEmpty) {
      return Container(
        decoration: BoxDecoration(
          color: CupertinoColors.systemGrey6.resolveFrom(context),
          borderRadius: BorderRadius.circular(6),
        ),
        alignment: Alignment.center,
        child: const Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            CupertinoActivityIndicator(radius: 9),
            SizedBox(height: 8),
            Text(
              'Waiting for dd progress…',
              style: TextStyle(
                fontSize: 12,
                color: CupertinoColors.tertiaryLabel,
              ),
            ),
          ],
        ),
      );
    }
    return Container(
      decoration: BoxDecoration(
        color: CupertinoColors.systemGrey6.resolveFrom(context),
        borderRadius: BorderRadius.circular(6),
        border: Border.all(color: CupertinoColors.separator, width: 0.5),
      ),
      padding: const EdgeInsets.all(12),
      child: ListView.builder(
        controller: _scroll,
        itemCount: widget.lines.length,
        itemBuilder: (context, i) {
          return Padding(
            padding: const EdgeInsets.symmetric(vertical: 1),
            child: Text(
              widget.lines[i],
              style: const TextStyle(
                fontFamilyFallback: monospaceFontFallback,
                fontSize: 11,
                height: 1.3,
              ),
            ),
          );
        },
      ),
    );
  }
}
