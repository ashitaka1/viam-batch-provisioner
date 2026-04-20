import 'package:flutter/cupertino.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/process_runner.dart';
import '../../models/batch.dart';
import '../../providers/provision_providers.dart';
import '../../providers/queue_providers.dart';
import '../../theme/theme.dart';

class ProvisionStagePanel extends ConsumerWidget {
  const ProvisionStagePanel({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final batch = ref.watch(currentBatchProvider);
    final session = ref.watch(provisionControllerProvider);

    return Padding(
      padding: const EdgeInsets.all(24),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _Header(batch: batch, session: session),
          const SizedBox(height: 16),
          Expanded(child: _OutputLog(lines: session.lines)),
        ],
      ),
    );
  }
}

class _Header extends StatelessWidget {
  const _Header({required this.batch, required this.session});
  final Batch? batch;
  final ProvisionSession session;

  @override
  Widget build(BuildContext context) {
    final b = batch;
    final Widget statusIcon;
    final String title;
    final String subtitle;

    if (session.isRunning) {
      statusIcon = const Padding(
        padding: EdgeInsets.only(right: 10, top: 4),
        child: CupertinoActivityIndicator(radius: 9),
      );
      title = 'Provisioning…';
      subtitle = 'Running cli/provision-batch.sh';
    } else if (session.hasRun && session.succeeded) {
      statusIcon = const Padding(
        padding: EdgeInsets.only(right: 10),
        child: Icon(
          CupertinoIcons.checkmark_circle_fill,
          size: 22,
          color: CupertinoColors.activeGreen,
        ),
      );
      title = 'Provisioning complete';
      subtitle = b != null
          ? '${b.count} machine${b.count == 1 ? '' : 's'} in queue'
          : '';
    } else if (session.hasRun) {
      statusIcon = const Padding(
        padding: EdgeInsets.only(right: 10),
        child: Icon(
          CupertinoIcons.xmark_circle_fill,
          size: 22,
          color: CupertinoColors.systemRed,
        ),
      );
      title = 'Provisioning failed';
      subtitle = 'Exit code ${session.exitCode}';
    } else if (b != null) {
      statusIcon = const Padding(
        padding: EdgeInsets.only(right: 10),
        child: Icon(
          CupertinoIcons.cube_box,
          size: 22,
          color: CupertinoColors.secondaryLabel,
        ),
      );
      title = 'Batch: ${b.prefix}';
      subtitle = '${b.count} machine${b.count == 1 ? '' : 's'}';
    } else {
      statusIcon = const SizedBox.shrink();
      title = 'Provision';
      subtitle = '';
    }

    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        statusIcon,
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                title,
                style: const TextStyle(
                  fontSize: 20,
                  fontWeight: FontWeight.w600,
                ),
              ),
              if (subtitle.isNotEmpty) ...[
                const SizedBox(height: 2),
                Text(
                  subtitle,
                  style: const TextStyle(
                    fontSize: 13,
                    color: CupertinoColors.secondaryLabel,
                  ),
                ),
              ],
            ],
          ),
        ),
      ],
    );
  }
}

class _OutputLog extends StatefulWidget {
  const _OutputLog({required this.lines});
  final List<ProcessLine> lines;

  @override
  State<_OutputLog> createState() => _OutputLogState();
}

class _OutputLogState extends State<_OutputLog> {
  final _scrollController = ScrollController();

  @override
  void didUpdateWidget(covariant _OutputLog oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.lines.length != oldWidget.lines.length) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (_scrollController.hasClients) {
          _scrollController.jumpTo(
            _scrollController.position.maxScrollExtent,
          );
        }
      });
    }
  }

  @override
  void dispose() {
    _scrollController.dispose();
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
        child: const Text(
          'No output yet.',
          style: TextStyle(
            fontSize: 12,
            color: CupertinoColors.tertiaryLabel,
          ),
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
        controller: _scrollController,
        itemCount: widget.lines.length,
        itemBuilder: (context, i) {
          final line = widget.lines[i];
          return Padding(
            padding: const EdgeInsets.symmetric(vertical: 1),
            child: Text(
              _stripAnsi(line.line),
              style: TextStyle(
                fontFamilyFallback: monospaceFontFallback,
                fontSize: 11,
                height: 1.3,
                color: line.isError
                    ? CupertinoColors.systemRed.resolveFrom(context)
                    : CupertinoColors.label.resolveFrom(context),
              ),
            ),
          );
        },
      ),
    );
  }

  static final _ansiRegex = RegExp(r'\x1B\[[0-9;]*[A-Za-z]');
  static String _stripAnsi(String s) => s.replaceAll(_ansiRegex, '');
}
