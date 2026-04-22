import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:macos_ui/macos_ui.dart';

import '../../models/batch.dart';
import '../../providers/environment_providers.dart';
import '../../providers/provision_providers.dart';
import '../../providers/queue_providers.dart';
import '../../theme/theme.dart';

class NewBatchForm extends ConsumerStatefulWidget {
  const NewBatchForm({super.key});

  @override
  ConsumerState<NewBatchForm> createState() => _NewBatchFormState();
}

class _NewBatchFormState extends ConsumerState<NewBatchForm> {
  final _prefixCtrl = TextEditingController();
  final _countCtrl = TextEditingController(text: '1');
  BatchTargetType _targetType = BatchTargetType.pi;
  String? _error;

  @override
  void dispose() {
    _prefixCtrl.dispose();
    _countCtrl.dispose();
    super.dispose();
  }

  Future<void> _create() async {
    final prefix = _prefixCtrl.text.trim();
    final count = int.tryParse(_countCtrl.text.trim());

    if (prefix.isEmpty) {
      setState(() => _error = 'Prefix is required.');
      return;
    }
    if (!RegExp(r'^[a-z0-9][a-z0-9-]*$').hasMatch(prefix)) {
      setState(
        () => _error = 'Prefix must be lowercase letters/digits/hyphens.',
      );
      return;
    }
    if (count == null || count < 1) {
      setState(() => _error = 'Count must be a positive integer.');
      return;
    }

    setState(() => _error = null);

    final repo = ref.read(queueRepositoryProvider);
    await repo.saveTargetType(_targetType == BatchTargetType.pi ? 'pi' : 'x86');

    await ref.read(provisionControllerProvider.notifier).run(
          prefix: prefix,
          count: count,
          targetType: _targetType,
        );
  }

  @override
  Widget build(BuildContext context) {
    final activeEnv = ref.watch(activeEnvironmentProvider).valueOrNull;
    final mode = activeEnv?.provisionMode ?? 'os-only';
    final noEnv = activeEnv == null;
    final session = ref.watch(provisionControllerProvider);

    return Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 480),
        child: Padding(
          padding: const EdgeInsets.all(32),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              const Text(
                'New Batch',
                style: TextStyle(fontSize: 22, fontWeight: FontWeight.w600),
              ),
              const SizedBox(height: 4),
              const Text(
                'A batch is a named group of machines provisioned together.',
                style: TextStyle(
                  fontSize: 13,
                  color: MacosColors.secondaryLabelColor,
                ),
              ),
              const SizedBox(height: 24),
              const _FieldLabel('Prefix'),
              MacosTextField(
                controller: _prefixCtrl,
                placeholder: 'lab-pi',
                autocorrect: false,
                enableSuggestions: false,
                enabled: !session.isRunning,
              ),
              const SizedBox(height: 4),
              const Text(
                'Machines will be named prefix-1, prefix-2, etc.',
                style: TextStyle(
                  fontSize: 11,
                  color: MacosColors.tertiaryLabelColor,
                ),
              ),
              const SizedBox(height: 16),
              const _FieldLabel('Count'),
              MacosTextField(
                controller: _countCtrl,
                keyboardType: TextInputType.number,
                enabled: !session.isRunning,
              ),
              const SizedBox(height: 16),
              const _FieldLabel('Target'),
              _TargetPicker(
                value: _targetType,
                enabled: !session.isRunning,
                onChanged: (v) => setState(() => _targetType = v),
              ),
              const SizedBox(height: 16),
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  const Text(
                    'Provision mode',
                    style: TextStyle(
                      fontSize: 13,
                      color: MacosColors.secondaryLabelColor,
                    ),
                  ),
                  Text(
                    mode,
                    style: const TextStyle(
                      fontSize: 13,
                      fontFamilyFallback: monospaceFontFallback,
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 4),
              const Text(
                'Set in the active environment (Settings).',
                style: TextStyle(
                  fontSize: 11,
                  color: MacosColors.tertiaryLabelColor,
                ),
              ),
              if (_error != null) ...[
                const SizedBox(height: 16),
                Text(
                  _error!,
                  style: const TextStyle(
                    fontSize: 13,
                    color: MacosColors.systemRedColor,
                  ),
                ),
              ],
              const SizedBox(height: 24),
              PushButton(
                controlSize: ControlSize.large,
                onPressed: (noEnv || session.isRunning) ? null : _create,
                child: Text(
                  session.isRunning ? 'Creating…' : 'Create Batch',
                ),
              ),
              if (noEnv) ...[
                const SizedBox(height: 8),
                const Text(
                  'Select or create an environment first.',
                  textAlign: TextAlign.center,
                  style: TextStyle(
                    fontSize: 12,
                    color: MacosColors.tertiaryLabelColor,
                  ),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

class _TargetPicker extends StatelessWidget {
  const _TargetPicker({
    required this.value,
    required this.enabled,
    required this.onChanged,
  });

  final BatchTargetType value;
  final bool enabled;
  final ValueChanged<BatchTargetType> onChanged;

  @override
  Widget build(BuildContext context) {
    const options = {
      BatchTargetType.pi: 'Raspberry Pi',
      BatchTargetType.x86: 'x86 PXE',
    };
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        for (final entry in options.entries)
          Padding(
            padding: const EdgeInsets.only(right: 8),
            child: PushButton(
              controlSize: ControlSize.regular,
              secondary: entry.key != value,
              onPressed: (entry.key == value || !enabled)
                  ? null
                  : () => onChanged(entry.key),
              child: Text(entry.value),
            ),
          ),
      ],
    );
  }
}

class _FieldLabel extends StatelessWidget {
  const _FieldLabel(this.label);
  final String label;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 6),
      child: Text(
        label,
        style: const TextStyle(
          fontSize: 12,
          fontWeight: FontWeight.w600,
          color: MacosColors.secondaryLabelColor,
        ),
      ),
    );
  }
}
