import 'plist.dart';

import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';

Never fail(String message) => throw FormatException(message);
dynamic readJson(String path) => jsonDecode(File(path).readAsStringSync());
String digest(List<int> bytes) => sha256.convert(bytes).toString();
void writeJson(String path, dynamic value) =>
    File(path).writeAsStringSync('${jsonEncode(value)}\n');
String quote(String value) => "'${value.replaceAll("'", "'\\''")}'";
Map<String, dynamic> readPlist(String path) {
  final bytes = File(path).readAsBytesSync();
  if (bytes.length >= 6 &&
      ascii.decode(bytes.take(6).toList(), allowInvalid: true) == 'bplist') {
    final result = Process.runSync('plutil', [
      '-convert',
      'xml1',
      '-o',
      '-',
      path,
    ]);
    if (result.exitCode != 0) fail('Binary plist conversion failed');
    return decodePlist(result.stdout as String) as Map<String, dynamic>;
  }
  return decodePlist(utf8.decode(bytes)) as Map<String, dynamic>;
}
