import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

import '../models/queue_entry.dart';

class QueueRepository {
  QueueRepository(this.repoRoot);
  final String repoRoot;

  String get machinesDir => p.join(repoRoot, 'http-server', 'machines');
  String get _queuePath => p.join(machinesDir, 'queue.json');
  String get _batchMetaPath => p.join(machinesDir, 'batch.json');

  Future<List<QueueEntry>> loadQueue() async {
    final file = File(_queuePath);
    if (!await file.exists()) return const [];
    try {
      final list = jsonDecode(await file.readAsString()) as List<dynamic>;
      return list
          .map((e) => QueueEntry.fromJson(e as Map<String, dynamic>))
          .toList();
    } on FormatException {
      return const [];
    }
  }

  Future<String?> loadTargetType() async {
    final file = File(_batchMetaPath);
    if (!await file.exists()) return null;
    try {
      final json = jsonDecode(await file.readAsString()) as Map<String, dynamic>;
      return json['target_type'] as String?;
    } on FormatException {
      return null;
    }
  }

  Future<void> saveTargetType(String targetType) async {
    await Directory(machinesDir).create(recursive: true);
    final file = File(_batchMetaPath);
    await file.writeAsString(jsonEncode({'target_type': targetType}));
  }
}
