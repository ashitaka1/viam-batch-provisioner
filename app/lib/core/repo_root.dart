import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path/path.dart' as p;

final repoRootProvider = Provider<String>((ref) {
  return _findRepoRoot();
});

String _findRepoRoot() {
  // Walk up from the executable looking for justfile as a sentinel
  var dir = Directory(p.dirname(Platform.resolvedExecutable));
  for (var i = 0; i < 10; i++) {
    if (File(p.join(dir.path, 'justfile')).existsSync()) {
      return dir.path;
    }
    final parent = dir.parent;
    if (parent.path == dir.path) break;
    dir = parent;
  }

  // Fallback: try current working directory
  final cwd = Directory.current.path;
  if (File(p.join(cwd, 'justfile')).existsSync()) {
    return cwd;
  }

  throw StateError(
    'Cannot find repo root. The app must be run from within the repository.',
  );
}
