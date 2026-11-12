import 'dart:io';
import 'dart:math';

import 'aab_manifest.dart';
import 'core.dart';
import 'resources.dart';
import 'plist.dart';

void runCommand(List<String> args) {
  if (args.isEmpty) fail('executor command is required');
  final a = args.skip(1).toList();
  switch (args.first) {
    case 'needs-studio':
      stdout.writeln(
        requiredResources(readJson(a[0]) as Map<String, dynamic>).keys
                .any((r) => r.startsWith('app-studio/'))
            ? 'yes'
            : 'no',
      );
    case 'package-response':
      packageResponse(a[0], a[1], a[2], a[3]);
    case 'stage':
      writeResources(
        a[2],
        verified(
          a[1],
          requiredResources(readJson(a[0]) as Map<String, dynamic>),
        ),
      );
    case 'materialize':
      final index = a[3].isNotEmpty
          ? a[3]
          : '${a[2].isNotEmpty ? a[2] : '${File(a[0]).parent.path}/frozen-resources'}/index.json';
      writeResources(
        a[1],
        verified(
          index,
          requiredResources(readJson(a[0]) as Map<String, dynamic>),
        ),
        indexName: 'resources.json',
      );
    case 'overlay':
      overlay(Directory(a[0]), Directory(a[1]));
    case 'settings':
      settings(a);
    case 'random-password':
      final random = Random.secure();
      stdout.writeln(
        List.generate(
          16,
          (_) => random.nextInt(256).toRadixString(16).padLeft(2, '0'),
        ).join(),
      );
    case 'profile':
      final profile = readPlist(a[0]);
      if (!(profile['TeamIdentifier'] as List<dynamic>? ?? []).contains(a[2]))
        fail('profile team mismatch');
      final appId =
          profile['Entitlements']?['application-identifier'] as String? ?? '';
      if (!_matchesProfileAppId(appId, a[2], a[1]))
        fail('profile bundle id mismatch');
      final expires = profile['ExpirationDate'];
      if (expires is! DateTime) fail('profile expiration missing');
      if (!expires.isAfter(DateTime.now().toUtc())) fail('profile expired');
      if ((profile['Name'] as String? ?? '').toLowerCase().contains('debug'))
        fail('debug profile cannot sign a release IPA');
    case 'app-info':
      final info = readPlist(a[0]);
      if (info['CFBundleIdentifier'] != a[1]) fail('app bundle id mismatch');
      if ('${info['CFBundleShortVersionString'] ?? ''}' != a[2])
        fail('app version mismatch');
      if ('${info['CFBundleVersion'] ?? ''}' != a[3])
        fail('app build number mismatch');
      if (a.length > 4 && info['CFBundleDisplayName'] != a[4])
        fail('built app display name mismatch');
    case 'entitlements':
      final entitlements = readPlist(a[0])['Entitlements'];
      if (entitlements is! Map || entitlements.isEmpty)
        fail('profile entitlements missing');
      File(a[1]).writeAsStringSync(encodePlist(entitlements));
    case 'aab-manifest':
      verifyAabManifest(a);
    case 'upload-grant':
      validateGrant(a);
    default:
      fail('Unknown executor command');
  }
}

void overlay(Directory source, Directory target) {
  if (!source.existsSync() || FileSystemEntity.isLinkSync(source.path))
    fail('Orion release overlay is missing');
  final files = <File>[];
  for (final entity in source.listSync(recursive: true, followLinks: false)) {
    if (entity is Link) fail('overlay symlink rejected');
    if (entity is File) files.add(entity);
  }
  if (files.isEmpty) fail('release overlay is empty');
  for (final file in files) {
    final relative = file.path.substring(source.path.length + 1);
    final dest = File('${target.path}/$relative');
    var parent = dest.parent;
    while (parent.path.length >= target.path.length) {
      if (FileSystemEntity.isLinkSync(parent.path))
        fail('overlay destination symlink rejected');
      parent = parent.parent;
    }
    if (FileSystemEntity.isLinkSync(dest.path))
      fail('overlay destination symlink rejected');
    dest.parent.createSync(recursive: true);
    file.copySync(dest.path);
  }
}

void settings(List<String> a) {
  final defines = readJson(a[0]) as Map<String, dynamic>,
      settings = readJson(a[1]) as Map<String, dynamic>,
      spec = readJson(a[2]);
  final app = spec['buildInput']['app'],
      env = spec['buildInput']['environment'];
  final required = {
    'APP_ENV': env['name'],
    'MERCURY_BASE_URL': env['mercuryBaseUrl'],
    'RUNTIME_BASE_URL': env['runtimeBaseUrl'],
    'RUNTIME_APP_BINDING': '${spec['appId']}',
    'RELEASE_CHANNEL': env['releaseChannel'],
  };
  for (final e in required.entries) {
    if (defines[e.key] != e.value)
      fail('frozen dart define mismatch: ${e.key}');
  }
  final expected = {
    'platform': spec['platform'],
    for (final key in [
      'applicationId',
      'bundleId',
      'displayName',
      'versionName',
      'versionCode',
    ])
      key: app[key],
  };
  for (final e in expected.entries) {
    if (settings[e.key] != e.value) fail('build-settings mismatch: ${e.key}');
  }
  final keys = {
    'FROZEN_APPLICATION_ID': 'applicationId',
    'FROZEN_BUNDLE_ID': 'bundleId',
    'FROZEN_DISPLAY_NAME': 'displayName',
    'FROZEN_VERSION_NAME': 'versionName',
    'FROZEN_VERSION_CODE': 'versionCode',
  };
  File(a[3]).writeAsStringSync(
    '${keys.entries.map((e) => '${e.key}=${quote('${settings[e.value]}')}').join('\n')}\n',
  );
}

void validateGrant(List<String> a) {
  final grant = readJson(a[0]);
  if (grant['target'] != a[1] ||
      grant['fileName'] != a[2] ||
      grant['contentType'] != a[3])
    fail('upload grant does not match the artifact');
  if (grant['byteSize'] != int.parse(a[4]) || grant['sha256'] != a[5])
    fail('upload grant size or digest does not match the artifact');
  final key = grant['objectKey'];
  if (key is! String ||
      key.isEmpty ||
      key.startsWith('/') ||
      key.contains('..') ||
      key.contains('\\') ||
      key.contains('://'))
    fail('upload grant objectKey rejected');
  if ((grant['method'] ?? 'PUT') != 'PUT')
    fail('upload grant method must be PUT');
  final url = Uri.parse(
    (grant['url'] ?? grant['uploadUrl'] ?? grant['presignedUrl'] ?? '')
        as String,
  );
  if (url.scheme != 'https' || url.host.isEmpty || url.userInfo.isNotEmpty)
    fail('upload URL must be https without credentials');
}

bool _matchesProfileAppId(String appId, String teamId, String bundleId) {
  if (appId == '$teamId.$bundleId' || appId == '$teamId.*') return true;
  if (appId.startsWith('$teamId.') && appId.endsWith('.*')) {
    final prefix = appId.substring(teamId.length + 1, appId.length - 2);
    return prefix.isNotEmpty && bundleId.startsWith('$prefix.');
  }
  return false;
}
