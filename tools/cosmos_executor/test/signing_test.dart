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
      void writeProfileWithAppId(String appId) => profile.writeAsStringSync(
        encodePlist({
          'TeamIdentifier': <dynamic>['TEAM'],
          'Entitlements': {'application-identifier': appId},
          'ExpirationDate': DateTime.now().toUtc().add(const Duration(days: 1)),
          'Name': 'Distribution',
        }),
      );
      writeProfileWithAppId('TEAM.*');
      expect(
        invoke(['profile', profile.path, 'com.example.app', 'TEAM']).exitCode,
        0,
      );
      writeProfileWithAppId('TEAM.com.example.*');
      expect(
        invoke(['profile', profile.path, 'com.example.app', 'TEAM']).exitCode,
        0,
      );
      expect(
        invoke(['profile', profile.path, 'com.other.app', 'TEAM']).exitCode,
        isNot(0),
      );
      final xmlManifest = File('${temp.path}/AndroidManifest.xml')
        ..writeAsStringSync(
          '<manifest xmlns:android="http://schemas.android.com/apk/res/android" '
          'package="com.example.app" android:versionCode="3" android:versionName="1.0.0"/>',
        );
      expect(
        invoke([
          'aab-manifest',
          xmlManifest.path,
          'com.example.app',
          '1.0.0',
          '3',
        ]).exitCode,
        0,
      );
      expect(
        invoke([
          'aab-manifest',
          xmlManifest.path,
          'com.example.app',
          '1.0.0',
          '4',
        ]).exitCode,
        isNot(0),
      );
      List<int> pbFieldBytes(int field, List<int> data) => [
        (field << 3) | 2,
        data.length,
        ...data,
      ];
      List<int> pbFieldVarint(int field, int value) {
        final out = <int>[(field << 3) | 0];
        var v = value;
        while (v >= 0x80) {
          out.add((v & 0x7F) | 0x80);
          v >>= 7;
        }
        out.add(v);
        return out;
      }
      List<int> pbAttr(
        String name, {
        String value = '',
        int resourceId = 0,
        List<int>? compiledItem,
      }) => [
        ...pbFieldBytes(2, name.codeUnits),
        if (value.isNotEmpty) ...pbFieldBytes(3, value.codeUnits),
        if (resourceId != 0) ...pbFieldVarint(5, resourceId),
        if (compiledItem != null) ...pbFieldBytes(6, compiledItem),
      ];
      final protoElement = <int>[
        ...pbFieldBytes(3, 'manifest'.codeUnits),
        ...pbFieldBytes(4, pbAttr('package', value: 'com.example.app')),
        ...pbFieldBytes(
          4,
          pbAttr('versionName', value: '1.0.0', resourceId: 0x0101021c),
        ),
        ...pbFieldBytes(
          4,
          pbAttr(
            'versionCode',
            resourceId: 0x0101021b,
            compiledItem: pbFieldBytes(7, pbFieldVarint(6, 3)),
          ),
        ),
      ];
      final protoManifest = File('${temp.path}/AndroidManifest.pb')
        ..writeAsBytesSync(pbFieldBytes(1, protoElement));
      expect(
        invoke([
          'aab-manifest',
          protoManifest.path,
          'com.example.app',
          '1.0.0',
          '3',
        ]).exitCode,
        0,
      );
      expect(
        invoke([
          'aab-manifest',
          protoManifest.path,
          'com.wrong.app',
          '1.0.0',
          '3',
        ]).exitCode,
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
