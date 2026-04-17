import 'queue_entry.dart';

enum BatchTargetType {
  pi('Raspberry Pi'),
  x86('x86 PXE');

  const BatchTargetType(this.label);
  final String label;
}

enum BatchStage {
  provision('Provision'),
  flash('Flash'),
  boot('Boot'),
  verify('Verify');

  const BatchStage(this.label);
  final String label;
}

class Batch {
  const Batch({
    required this.prefix,
    required this.entries,
    required this.targetType,
    required this.provisionMode,
  });

  final String prefix;
  final List<QueueEntry> entries;
  final BatchTargetType targetType;
  final String provisionMode;

  int get count => entries.length;
  int get assignedCount => entries.where((e) => e.assigned).length;

  List<BatchStage> get stages => switch (targetType) {
        BatchTargetType.pi => const [
            BatchStage.provision,
            BatchStage.flash,
            BatchStage.verify,
          ],
        BatchTargetType.x86 => const [
            BatchStage.provision,
            BatchStage.boot,
            BatchStage.verify,
          ],
      };
}
