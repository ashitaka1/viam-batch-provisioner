import 'dart:io';

import 'process_runner.dart';

Future<ProcessResult> runPrivileged(
  String executable,
  List<String> arguments,
) async {
  final command = [executable, ...arguments]
      .map((a) => a.contains(' ') ? "'$a'" : a)
      .join(' ');

  return Process.run(
    'osascript',
    ['-e', 'do shell script "$command" with administrator privileges'],
  );
}

/// Prompts for admin credentials via the macOS dialog and caches them with
/// `sudo -v`. Returns true on success. Subsequent `sudo -n ...` calls will
/// run without re-prompting until the sudo timestamp expires (default 5 min).
Future<bool> acquireSudo() async {
  final result = await Process.run(
    'osascript',
    ['-e', 'do shell script "sudo -v" with administrator privileges'],
  );
  return result.exitCode == 0;
}

/// Streams a privileged process (e.g. dnsmasq, pxe-watcher, dd). Requires
/// a prior successful [acquireSudo] so `sudo -n` runs non-interactively.
Stream<ProcessEvent> startPrivileged({
  required String executable,
  required List<String> arguments,
  required String workingDirectory,
  Map<String, String>? environment,
}) {
  return runProcess(
    executable: '/usr/bin/sudo',
    arguments: ['-n', executable, ...arguments],
    workingDirectory: workingDirectory,
    environment: environment,
  );
}

Future<List<String>> listNetworkInterfaces() async {
  final result = await Process.run(
    'networksetup',
    ['-listallhardwareports'],
  );
  final lines = (result.stdout as String).split('\n');
  final interfaces = <String>[];
  for (final line in lines) {
    if (line.startsWith('Device: ')) {
      interfaces.add(line.substring(8).trim());
    }
  }
  return interfaces;
}

Future<String?> defaultEthernetInterface() async {
  final result = await Process.run(
    'networksetup',
    ['-listallhardwareports'],
  );
  final output = result.stdout as String;
  final sections = output.split('\n\n');
  for (final section in sections) {
    if (section.contains('Ethernet') || section.contains('Thunderbolt')) {
      final deviceMatch = RegExp(r'Device:\s*(\S+)').firstMatch(section);
      if (deviceMatch != null) return deviceMatch.group(1);
    }
  }
  return null;
}
