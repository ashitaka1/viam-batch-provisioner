import 'dart:async';
import 'dart:convert';
import 'dart:io';

sealed class ProcessEvent {
  const ProcessEvent();
}

class ProcessLine extends ProcessEvent {
  const ProcessLine(this.line, {this.isError = false});
  final String line;
  final bool isError;
}

class ProcessExit extends ProcessEvent {
  const ProcessExit(this.exitCode);
  final int exitCode;
  bool get ok => exitCode == 0;
}

Stream<ProcessEvent> runProcess({
  required String executable,
  required List<String> arguments,
  required String workingDirectory,
  Map<String, String>? environment,
}) async* {
  final process = await Process.start(
    executable,
    arguments,
    workingDirectory: workingDirectory,
    environment: environment,
  );

  final events = StreamController<ProcessEvent>();

  final stdoutDone = process.stdout
      .transform(utf8.decoder)
      .transform(const LineSplitter())
      .forEach((line) => events.add(ProcessLine(line)));
  final stderrDone = process.stderr
      .transform(utf8.decoder)
      .transform(const LineSplitter())
      .forEach((line) => events.add(ProcessLine(line, isError: true)));

  unawaited(
    Future.wait([stdoutDone, stderrDone, process.exitCode]).then((results) {
      events.add(ProcessExit(results[2] as int));
      events.close();
    }),
  );

  yield* events.stream;
}
