import 'dart:convert';
import 'dart:io';

import 'core.dart';

Map<String, String> requiredResources(Map<String, dynamic> spec) {
  final rows = spec['buildInput']?['resources'];
  if (rows is! List) fail('buildInput.resources is missing');
  final result = <String, String>{};
  for (final row in rows) {
    final ref = row['ref'], hash = row['digest'];
    if (ref is! String || hash is! String)
      fail('buildInput.resources ref is invalid');
    if (result.containsKey(ref) && result[ref] != hash)
      fail('frozen ref digest conflict');
    result[ref] = hash;
  }
  return result;
}

File locateResource(File index, String raw) {
  if (raw.isEmpty ||
      raw.contains('://') ||
      raw.contains('\\') ||
      raw.contains('\x00') ||
      raw.split('/').contains('..') ||
      raw.split('/').contains('.'))
    fail('resource index path rejected');
  final requested = File(
    raw.startsWith('/') ? raw : '${index.parent.path}/$raw',
  ).absolute;
  var current = requested.path.startsWith('/') ? '/' : '';
  for (final step in requested.path.split('/').where((s) => s.isNotEmpty)) {
    current = '$current/$step';
    if (FileSystemEntity.isLinkSync(current)) fail('resource symlink rejected');
  }
  final root = index.parent.resolveSymbolicLinksSync(),
      resolved = requested.resolveSymbolicLinksSync();
  if (!resolved.startsWith('$root/'))
    fail('resource file escapes the index directory');
  if (!requested.existsSync()) fail('frozen resource file missing');
  return requested;
}

Map<String, List<int>> verified(
  String indexPath,
  Map<String, String> required,
) {
  final index = File(indexPath);
  if (FileSystemEntity.isLinkSync(indexPath)) fail('resource symlink rejected');
  if (!index.existsSync()) fail('frozen resource index is missing');
  final mapping = readJson(index.path);
  if (mapping is! Map || mapping.values.any((v) => v is! String))
    fail('resource index must map frozen refs to local paths');
  if (mapping.length != required.length ||
      !required.keys.every(mapping.containsKey))
    fail('resource index refs do not match the frozen spec');
  final files = <String, List<int>>{};
  for (final entry in required.entries) {
    final bytes = locateResource(
      index,
      mapping[entry.key] as String,
    ).readAsBytesSync();
    if (digest(bytes) != entry.value)
      fail('frozen resource digest mismatch: ${entry.key}');
    files[entry.key] = bytes;
  }
  return files;
}

void writeResources(
  String path,
  Map<String, List<int>> files, {
  String indexName = 'index.json',
  bool requireEmpty = true,
}) {
  final output = Directory(path);
  output.createSync(recursive: true);
  if (FileSystemEntity.isLinkSync(path) ||
      (requireEmpty && output.listSync().isNotEmpty))
    fail('frozen resource output is not empty');
  final index = <String, String>{};
  for (final entry in files.entries) {
    final name = digest(utf8.encode(entry.key));
    final file = File('$path/$name');
    if (file.existsSync() || FileSystemEntity.isLinkSync(file.path))
      fail('resource output path rejected');
    file.writeAsBytesSync(entry.value);
    index[entry.key] = name;
  }
  writeJson('$path/$indexName', index);
}

Map<String, List<int>> decodePackaging(
  dynamic payload,
  Map<String, String> studio,
) {
  const maxBytes = 36 * 1024 * 1024;
  if (payload is! List ||
      payload.length != studio.length ||
      payload.length > 512)
    fail('packaging resources do not match the frozen spec');
  final result = <String, List<int>>{};
  var total = 0;
  for (final row in payload) {
    if (row is! Map ||
        row.keys.any(
          (key) =>
              !['ref', 'digest', 'contentType', 'contentBase64'].contains(key),
        ))
      fail('packaging resource is invalid');
    final ref = row['ref'];
    if (ref is! String ||
        !studio.containsKey(ref) ||
        studio[ref] != row['digest'])
      fail('packaging resource ref is not in the frozen spec');
    if (![
      'image/png',
      'image/svg+xml',
      'image/webp',
      'application/zip',
    ].contains(row['contentType']))
      fail('packaging resource content type rejected');
    final encoded = row['contentBase64'];
    if (encoded is! String ||
        encoded.isEmpty ||
        encoded.length > (maxBytes ~/ 3) * 4 + 4 ||
        !RegExp(r'^[A-Za-z0-9+/]*={0,2}$').hasMatch(encoded) ||
        encoded.length % 4 != 0)
      fail('packaging resource payload rejected');
    final bytes = base64Decode(encoded);
    total += bytes.length;
    if (bytes.isEmpty || total > maxBytes)
      fail('packaging resource payload rejected');
    if (digest(bytes) != row['digest'])
      fail('packaging resource digest mismatch: $ref');
    if (result.containsKey(ref)) fail('packaging resource ref repeated');
    result[ref] = bytes;
  }
  return result;
}

void packageResponse(
  String specPath,
  String responsePath,
  String output,
  String legacyIndex,
) {
  final required = requiredResources(
    readJson(specPath) as Map<String, dynamic>,
  );
  final studio = Map<String, String>.fromEntries(
    required.entries.where((e) => e.key.startsWith('app-studio/')),
  );
  final legacy = Map<String, String>.fromEntries(
    required.entries.where((e) => !e.key.startsWith('app-studio/')),
  );
  if (studio.isEmpty) fail('spec has no App Studio resources');
  final files = decodePackaging(readJson(responsePath), studio);
  if (legacy.isNotEmpty) {
    if (legacyIndex.isEmpty)
      fail('authorized frozen resource index is missing');
    files.addAll(verified(legacyIndex, legacy));
  }
  writeResources(output, files);
}
