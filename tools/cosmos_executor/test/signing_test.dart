import 'dart:io';

import 'package:test/test.dart';
import 'package:cosmos_executor/core.dart';
import 'package:cosmos_executor/plist.dart';

void main() {
  test(
    'iOS profile/app identity and expiry fail closed; grant binds artifact',
    () {
      final temp = Directory.systemTemp.createTempSync('runall-signing-');
      addTearDown(() => temp.deleteSync(recursive: true));
      final root = Directory.current.path;
      ProcessResult invoke(List<String> args) => Process.runSync(
        Platform.resolvedExecutable,
        ['run', '$root/bin/executor.dart', ...args],
      );
      final profile = File('${temp.path}/profile.plist');
      void writeProfile(DateTime expiration) => profile.writeAsStringSync(
        encodePlist({
          'TeamIdentifier': <dynamic>['TEAM'],
          'Entitlements': {'application-identifier': 'TEAM.com.example.app'},
          'ExpirationDate': expiration,
          'Name': 'Distribution',
        }),
      );
      writeProfile(DateTime.now().toUtc().add(const Duration(days: 1)));
      expect(
        invoke(['profile', profile.path, 'com.example.app', 'TEAM']).exitCode,
        0,
      );
      expect(
        invoke(['profile', profile.path, 'com.wrong.app', 'TEAM']).exitCode,
        isNot(0),
      );
      expect(
        invoke(['profile', profile.path, 'com.example.app', 'OTHER']).exitCode,
        isNot(0),
      );
      writeProfile(DateTime.utc(2000));
      expect(
        invoke(['profile', profile.path, 'com.example.app', 'TEAM']).exitCode,
        isNot(0),
      );
      final info = File('${temp.path}/Info.plist')
        ..writeAsStringSync(
          encodePlist({
            'CFBundleIdentifier': 'com.example.app',
            'CFBundleShortVersionString': '1.0.0',
            'CFBundleVersion': '3',
            'CFBundleDisplayName': 'Example',
          }),
        );
      expect(
        invoke([
          'app-info',
          info.path,
          'com.example.app',
          '1.0.0',
          '3',
          'Example',
        ]).exitCode,
        0,
      );
      expect(
        invoke(['app-info', info.path, 'com.example.app', '1.0.1', '3'])
            .exitCode,
        isNot(0),
      );
      final grant = {
        'target': 'apk',
        'fileName': 'app.apk',
        'contentType': 'application/vnd.android.package-archive',
        'byteSize': 3,
        'sha256': 'a' * 64,
        'objectKey': 'build/1/app.apk',
        'url': 'https://objects.example.test/upload',
        'method': 'PUT',
      };
      final path = '${temp.path}/grant.json';
      ProcessResult check() => invoke([
        'upload-grant',
        path,
        'apk',
        'app.apk',
        'application/vnd.android.package-archive',
        '3',
        'a' * 64,
      ]);
      writeJson(path, grant);
      expect(check().exitCode, 0);
      for (final mutation in [
        {'method': 'POST'},
        {'objectKey': '../secret'},
        {'url': 'http://objects.example.test/upload'},
        {'byteSize': 4},
        {'fileName': 'other.apk'},
      ]) {
        writeJson(path, {...grant, ...mutation});
        expect(check().exitCode, isNot(0));
      }
    },
    timeout: const Timeout(Duration(minutes: 2)),
  );
}
