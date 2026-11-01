import 'dart:io';

import 'package:cosmos_executor/commands.dart';

void main(List<String> args) {
  try {
    runCommand(args);
  } on FormatException catch (e) {
    stderr.writeln(e.message);
    exitCode = 1;
  } catch (_) {
    stderr.writeln('Executor input validation failed');
    exitCode = 1;
  }
}
