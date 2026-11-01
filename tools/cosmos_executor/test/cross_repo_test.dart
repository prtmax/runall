import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:cosmos_executor/plist.dart';
import 'package:test/test.dart';
import 'package:cosmos_executor/core.dart';
import 'package:cosmos_executor/resources.dart';

void main() {
  final orion = Platform.environment['ORION_ROOT'],
      cosmos = Platform.environment['COSMOS_ROOT'];
  final executor = Directory.current.parent.parent.path;
  test(
    'canonical build vectors still match the platform authority',
    () {
      final vectors = readJson(
        '$cosmos/fornax/dalim/fixtures/native/canonical-vectors.json',
      ) as List<dynamic>;
      for (final vector in vectors.where(
        (v) => (v['kind'] as String).startsWith('build'),
      )) {
        final temp = Directory.systemTemp.createTempSync('runall-vector-');
        addTearDown(() => temp.deleteSync(recursive: true));
        writeJson('${temp.path}/input.json', {
          'buildInput': vector['normalized'],
        });
        final result = Process.runSync('node', [
          '$executor/scripts/lib/native_digest.js',
          'input',
          '${temp.path}/input.json',
        ]);
        expect(result.exitCode, 0, reason: '${result.stderr}');
        expect((result.stdout as String).trim(), vector['digest']);
      }
    },
    skip: cosmos == null
        ? 'Set COSMOS_ROOT for cross-repository validation'
        : false,
  );
  test('prepare verifies, stages and assembles Android/iOS and multi-style inputs', () {
    final cases = readJson(
      '$orion/tools/rigel_build/test/fixtures/assembly.json',
    ) as List<dynamic>;
    final valid = cases
        .where((c) => !((c as Map).containsKey('error')))
        .toList();
    final chosen = <dynamic>[
      valid.first,
      valid.firstWhere((c) => c['spec']['platform'] == 'ios'),
      valid.firstWhere(
        (c) =>
            c['spec']['buildInput']['schemaVersion'] ==
            'cosmos.native-build.v2',
      ),
    ];
    for (final row in chosen) {
      final temp = Directory.systemTemp.createTempSync('runall-cross-');
      addTearDown(() => temp.deleteSync(recursive: true));
      final spec = row['spec'] as Map<String, dynamic>;
      final mapping = row['resources'] as Map<String, dynamic>;
      final payload = <Map<String, dynamic>>[];
      final seen = <String>{};
      for (final resource in spec['buildInput']['resources'] as List<dynamic>) {
        final old = resource['ref'] as String;
        final ref = 'app-studio/$old';
        resource['ref'] = ref;
        if (!seen.add(ref)) continue;
        final bytes = File(
          '$orion/tools/rigel_build/test/fixtures/blobs/${mapping[old]}',
        ).readAsBytesSync();
        payload.add({
          'ref': ref,
          'digest': digest(bytes),
          'contentType': resource['kind'] == 'localization'
              ? 'application/zip'
              : 'image/png',
          'contentBase64': base64Encode(bytes),
        });
      }
      writeJson('${temp.path}/spec.json', spec);
      writeJson('${temp.path}/response.json', payload);
      packageResponse(
        '${temp.path}/spec.json',
        '${temp.path}/response.json',
        '${temp.path}/prepared',
        '',
      );
      writeResources(
        '${temp.path}/staged',
        verified('${temp.path}/prepared/index.json', requiredResources(spec)),
      );
      final result = Process.runSync(Platform.resolvedExecutable, [
        'run',
        '$orion/tools/rigel_build/bin/assemble.dart',
        '${temp.path}/spec.json',
        '${temp.path}/out',
        '${temp.path}/staged/index.json',
      ]);
      expect(result.exitCode, 0, reason: '${result.stderr}');
      expect(
        File('${temp.path}/out/overlay/lib/bootstrap/development_assembly.dart')
            .readAsStringSync(),
        row['assembly'],
      );
      final overlay = '${temp.path}/out/overlay';
      final assets =
          readJson('$overlay/assets/build/bundled_theme_assets.json')['assets']
              as Map<String, dynamic>;
      final expectedAssets = {
        for (final r in spec['buildInput']['resources'] as List<dynamic>)
          if (r['kind'] == 'feature_asset') r['key'],
      };
      expect(assets.keys.toSet(), expectedAssets);
      for (final resource in spec['buildInput']['resources'] as List<dynamic>) {
        final name = digest(utf8.encode(resource['ref'] as String));
        final frozen = File('${temp.path}/staged/$name').readAsBytesSync();
        expect(digest(frozen), resource['digest']);
        if (resource['kind'] == 'feature_asset')
          expect(
            File('$overlay/${assets[resource['key']]}').readAsBytesSync(),
            frozen,
          );
      }
      final language = readJson('$overlay/assets/fluent/manifest.json');
      expect(language['defaultLocale'], 'en-US');
      expect(language['referenceLocale'], 'zh-CN');
      expect(
        File('$overlay/assets/fluent/zh-CN.ftl').readAsStringSync(),
        'hello = 你好\n',
      );
      if (spec['platform'] == 'android') {
        final manifest = File(
          '$overlay/android/app/src/main/AndroidManifest.xml',
        ).readAsStringSync();
        expect(
          manifest,
          contains(
            'android:label="${spec['buildInput']['app']['displayName']}"',
          ),
        );
        expect(manifest, contains('tools:node="replace"'));
        expect(
          File('$overlay/android/app/build.gradle.kts').readAsStringSync(),
          contains('ANDROID_APPLICATION_ID'),
        );
      } else {
        expect(
          decodePlist(
            File('$overlay/ios/Runner/Info.plist').readAsStringSync(),
          )['CFBundleDisplayName'],
          r'$(APP_DISPLAY_NAME)',
        );
        expect(
          File('$overlay/ios/Flutter/Branded.xcconfig').readAsStringSync(),
          contains('IOS_BUNDLE_ID=${spec['buildInput']['app']['bundleId']}'),
        );
        expect(
          File('$overlay/ios/Runner.xcodeproj/project.pbxproj')
              .readAsStringSync(),
          contains(r'PRODUCT_BUNDLE_IDENTIFIER = $(IOS_BUNDLE_ID)'),
        );
        final bytes = File(
          '$overlay/ios/Runner/Assets.xcassets/AppIcon.appiconset/Icon-App-20x20@1x.png',
        ).readAsBytesSync();
        expect(ByteData.sublistView(bytes).getUint32(16), 20);
      }
      if (spec['platform'] == 'android' &&
          spec['buildInput']['schemaVersion'] == 'cosmos.native-build.v1') {
        final build = spec['buildInput'];
        final tokens = readJson(
          '$cosmos/solar/mercury/internal/theme/testdata/native-theme-tokens.json',
        );
        for (final theme in build['themes'] as List<dynamic>)
          theme['tokens'] = tokens;
        writeJson('${temp.path}/theme.json', spec);
        final theme = Process.runSync(Platform.resolvedExecutable, [
          'run',
          '$orion/tools/rigel_build/bin/assemble.dart',
          '${temp.path}/theme.json',
          '${temp.path}/theme-out',
          '${temp.path}/staged/index.json',
        ]);
        expect(theme.exitCode, 0, reason: '${theme.stderr}');
        expect(
          File(
            '${temp.path}/theme-out/overlay/lib/bootstrap/development_assembly.dart',
          ).readAsStringSync(),
          contains('#0B6BCB'),
        );
        build['app']['displayName'] = r'${throw StateError("injected")}';
        writeJson('${temp.path}/unsafe.json', spec);
        final unsafe = Process.runSync(Platform.resolvedExecutable, [
          'run',
          '$orion/tools/rigel_build/bin/assemble.dart',
          '${temp.path}/unsafe.json',
          '${temp.path}/unsafe-out',
          '${temp.path}/staged/index.json',
        ]);
        expect(unsafe.exitCode, isNot(0));
        build['app']['displayName'] = 'Example';
        build['environment']['runtimeBaseUrl'] =
            r'https://example.test/${runtime}';
        writeJson('${temp.path}/literal.json', spec);
        final literal = Process.runSync(Platform.resolvedExecutable, [
          'run',
          '$orion/tools/rigel_build/bin/assemble.dart',
          '${temp.path}/literal.json',
          '${temp.path}/literal-out',
          '${temp.path}/staged/index.json',
        ]);
        expect(literal.exitCode, 0, reason: '${literal.stderr}');
        expect(
          File(
            '${temp.path}/literal-out/overlay/lib/bootstrap/development_assembly.dart',
          ).readAsStringSync(),
          contains(r'https://example.test/\${runtime}'),
        );
      }
    }
  }, skip: orion == null ? 'Set ORION_ROOT for cross-repository validation' : false);
}
