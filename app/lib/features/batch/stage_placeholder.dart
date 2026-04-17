import 'package:flutter/cupertino.dart';

import '../../models/batch.dart';

class StagePlaceholder extends StatelessWidget {
  const StagePlaceholder({super.key, required this.stage});
  final BatchStage stage;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              stage.label,
              style: const TextStyle(fontSize: 22, fontWeight: FontWeight.w600),
            ),
            const SizedBox(height: 12),
            Text(
              _subtitle(stage),
              style: const TextStyle(
                fontSize: 13,
                color: CupertinoColors.secondaryLabel,
              ),
              textAlign: TextAlign.center,
            ),
          ],
        ),
      ),
    );
  }

  String _subtitle(BatchStage stage) {
    return switch (stage) {
      BatchStage.flash => 'SD card flashing arrives in Phase 5.',
      BatchStage.boot => 'PXE services arrive in Phase 4.',
      BatchStage.verify => 'Post-provision summary arrives in Phase 6.',
      BatchStage.provision => '',
    };
  }
}
